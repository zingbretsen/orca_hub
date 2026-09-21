defmodule OrcaHub.Cluster.CodeSync do
  @moduledoc """
  Hot code push: loads compiled `.beam` files onto remote nodes via
  `:code.load_binary/3` over `:erpc`.

  This is the low-level primitive. It is deliberately paranoid — every way a
  hot push can quietly corrupt a running node is turned into a refusal with a
  named reason rather than a best-effort attempt:

    * **Third code version.** `:code.soft_purge/1` returns `false` and does
      *nothing* when processes are still running the module's old code.
      Loading anyway would make the new code a third generation, which kills
      every process still on the oldest. So a `false` from `soft_purge`
      REFUSES that module and reports it as `wedged`. `:code.purge/1` (which
      kills those processes) is never called, not even as a fallback.
    * **ERTS skew.** OTP guarantees bytecode produced by an OLDER compiler
      runs on a NEWER runtime, not the reverse. `push/3` compares
      `:erlang.system_info(:version)` here against the target node and
      refuses on any mismatch (`allow_erts_mismatch: true` overrides). Exact
      equality is the bar on purpose: the older-here/newer-there direction is
      technically supported but is not a combination anything tests, and a
      loud refusal is cheaper than a node that half-works.
    * **Identical modules.** Re-loading a module whose code is already
      byte-identical on the target buys nothing and *costs* a code
      generation. Those are skipped, by md5, without shipping the binary.

  ## md5 is the module's, not the file's

  Differencing uses the module's COMPILE-TIME md5 — what
  `:erlang.get_module_info(mod, :md5)` / `mod.module_info(:md5)` /
  `:beam_lib.md5(binary)` all return, and what a remote node can report for
  code it is currently running. It is NOT `:erlang.md5/1` over the `.beam`
  file bytes, which hashes the whole container (debug info, docs, chunk
  padding) and therefore differs for identical code. Mixing the two silently
  reports everything as drifted.

  (`:code.module_md5/1` also works but only in embedded mode — releases —
  not under `mix`, which is why the remote side asks `:erlang.get_module_info/2`.)

  ## Modules that are never pushed

    * `OrcaHub.BuildInfo` — its `@sha`/`@built_at` are compile-time module
      attributes baked from the COMPILING machine's git state. Pushing it
      makes `/api/version` report the compiling host's HEAD instead of what
      the fleet is actually running, which breaks the one signal the deploy
      script uses to verify itself. Excluded from every payload by
      `load_beams/1`.
    * `#{inspect(__MODULE__)}` itself is pushed LAST if at all, never in the
      middle of an iteration over a payload containing it — swapping the
      pusher's own code mid-push is how you get half a push under one version
      and half under another. (`include_self: false` drops it entirely.)

  ## Topology

  The cluster is a STAR (`-kernel connect_all false`): the hub sees every
  agent, each agent sees only the hub. Fan-out must originate at the hub;
  `Node.list/0` on an agent is not the fleet.
  """

  require Logger

  @app :orca_hub

  # See the moduledoc. Excluded from every payload load_beams/1 produces.
  @excluded_modules [OrcaHub.BuildInfo]

  @default_timeout 15_000
  @erts_probe_timeout 5_000

  @type entry :: %{module: module(), binary: binary(), md5: binary(), path: charlist()}

  @type push_report :: %{
          loaded: [module()],
          skipped_identical: [module()],
          wedged: [module()],
          errors: [String.t()]
        }

  @type drift_report :: %{missing: [module()], drifted: [module()], identical: [module()]}

  # -------------------------------------------------------------------
  # Payload
  # -------------------------------------------------------------------

  @doc "The ebin directory of the currently-running `:orca_hub` application."
  @spec default_ebin_dir() :: Path.t()
  def default_ebin_dir, do: Application.app_dir(@app, "ebin")

  @doc """
  Read every `.beam` in `dir` into a push payload.

  `dir` is arbitrary — a freshly compiled `_build/prod/lib/orca_hub/ebin` is
  the intended source, not just whatever this node happens to be running.
  Defaults to `default_ebin_dir/0` for the "push what I'm running" case.

  The module name comes from the beam's own metadata rather than the
  filename, so this works for a directory whose modules were never loaded
  here (no `String.to_existing_atom/1` landmine).

  Entries come back sorted by module name, with `@excluded_modules` removed.
  """
  @spec load_beams(Path.t()) :: {:ok, [entry()]} | {:error, term()}
  def load_beams(dir \\ default_ebin_dir()) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".beam"))
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
          case read_entry(Path.join(dir, file)) do
            {:ok, :excluded} -> {:cont, {:ok, acc}}
            {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, entries} -> {:ok, Enum.sort_by(entries, & &1.module)}
          {:error, _} = error -> error
        end

      {:error, reason} ->
        {:error, {:unreadable_dir, dir, reason}}
    end
  end

  defp read_entry(path) do
    with {:ok, binary} <- File.read(path),
         {:ok, {mod, md5}} <- :beam_lib.md5(binary) do
      if mod in @excluded_modules do
        {:ok, :excluded}
      else
        {:ok, %{module: mod, binary: binary, md5: md5, path: to_charlist(path)}}
      end
    else
      {:error, :beam_lib, reason} -> {:error, {:bad_beam, path, reason}}
      {:error, reason} -> {:error, {:unreadable, path, reason}}
    end
  end

  # -------------------------------------------------------------------
  # Compatibility
  # -------------------------------------------------------------------

  @doc """
  Whether bytecode compiled by THIS node's toolchain may be loaded on
  `target_node`.

  Returns `:ok`, `{:error, {:erts_mismatch, local, remote}}` with both
  version strings named, or an error describing why the node could not be
  reached at all.
  """
  @spec compatible?(node(), timeout()) ::
          :ok | {:error, {:erts_mismatch, String.t(), String.t()}} | {:error, term()}
  def compatible?(target_node, timeout \\ @erts_probe_timeout) when is_atom(target_node) do
    case remote_erts_version(target_node, timeout) do
      {:ok, remote} -> erts_verdict(local_erts_version(), remote)
      {:error, _} = error -> error
    end
  end

  # The comparison itself, split out so it is testable without two runtimes
  # on the box. Exact equality on purpose — see the moduledoc.
  @doc false
  @spec erts_verdict(String.t(), String.t()) ::
          :ok | {:error, {:erts_mismatch, String.t(), String.t()}}
  def erts_verdict(local, local) when is_binary(local), do: :ok
  def erts_verdict(local, remote), do: {:error, {:erts_mismatch, local, remote}}

  @doc "This node's ERTS version, e.g. `\"15.2.7.9\"`."
  @spec local_erts_version() :: String.t()
  def local_erts_version, do: :erlang.system_info(:version) |> List.to_string()

  defp remote_erts_version(target_node, timeout) do
    try do
      {:ok,
       target_node |> :erpc.call(:erlang, :system_info, [:version], timeout) |> List.to_string()}
    catch
      kind, reason -> {:error, {:unreachable, target_node, {kind, reason}}}
    end
  end

  # -------------------------------------------------------------------
  # Drift
  # -------------------------------------------------------------------

  @doc """
  Compare a payload against what `target_node` is currently running.

  `missing` are modules the node has not loaded at all, `drifted` are ones
  whose running md5 differs from the payload's, `identical` need no push.
  """
  @spec drift([entry()], node(), keyword()) :: {:ok, drift_report()} | {:error, term()}
  def drift(entries, target_node, opts \\ []) when is_list(entries) and is_atom(target_node) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    with {:ok, remote} <- remote_md5s(target_node, Enum.map(entries, & &1.module), timeout) do
      {missing, drifted, identical} =
        Enum.reduce(entries, {[], [], []}, fn entry, {missing, drifted, identical} ->
          case Map.get(remote, entry.module, :missing) do
            :missing -> {[entry.module | missing], drifted, identical}
            md5 when md5 == entry.md5 -> {missing, drifted, [entry.module | identical]}
            _other -> {missing, [entry.module | drifted], identical}
          end
        end)

      {:ok,
       %{
         missing: Enum.sort(missing),
         drifted: Enum.sort(drifted),
         identical: Enum.sort(identical)
       }}
    end
  end

  # Fetches the running md5 of many modules in ONE round of pipelined erpc
  # requests rather than 277 sequential calls. Requests all go out first,
  # then responses are collected against a single absolute deadline, so an
  # unreachable node costs `timeout` total instead of `timeout` per module.
  defp remote_md5s(_target_node, [], _timeout), do: {:ok, %{}}

  defp remote_md5s(target_node, modules, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout

    requests =
      Enum.map(modules, fn mod ->
        {mod, :erpc.send_request(target_node, :erlang, :get_module_info, [mod, :md5])}
      end)

    Enum.reduce_while(requests, {:ok, %{}}, fn {mod, request_id}, {:ok, acc} ->
      case await_md5(request_id, deadline) do
        {:ok, md5} -> {:cont, {:ok, Map.put(acc, mod, md5)}}
        :missing -> {:cont, {:ok, Map.put(acc, mod, :missing)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  catch
    kind, reason -> {:error, {:unreachable, target_node, {kind, reason}}}
  end

  # A remote `get_module_info/2` on a module the node has not loaded raises
  # `badarg` there, which erpc re-raises here — that means "missing", not
  # "broken". Transport failures (timeout, lost connection) are real errors
  # and must NOT be laundered into "missing", or a dead node would look like
  # a node that simply needs every module pushed.
  defp await_md5(request_id, deadline) do
    try do
      {:ok, :erpc.receive_response(request_id, {:abs, deadline})}
    catch
      :error, {:erpc, :timeout} -> {:error, :timeout}
      :exit, {:erpc, :timeout} -> {:error, :timeout}
      :error, {:erpc, :noconnection} -> {:error, :noconnection}
      :exit, {:erpc, :noconnection} -> {:error, :noconnection}
      :error, {:erpc, reason} -> {:error, {:erpc, reason}}
      :exit, {:erpc, reason} -> {:error, {:erpc, reason}}
      _kind, _reason -> :missing
    end
  end

  @doc """
  Why `target` reported each of `modules` as `missing` — the precision
  `drift/3` cannot supply on its own.

  `drift/3` learns "missing" by asking `:erlang.get_module_info/2`, which
  raises for a module the node has not LOADED. That single answer covers
  two very different situations, and an operator handed one number cannot
  tell them apart:

    * `:not_loaded` — the module sits in the node's code path and would be
      loaded on demand. Under a release (embedded mode, everything in the
      boot script is loaded up front) this is unusual and interesting; under
      `mix` it is ordinary.
    * `:absent` — `:code.which/1` says `:non_existing`. The node genuinely
      does not have this module anywhere and never will without a push.

  `:code.which/1` answers exactly this question and answers it in embedded
  mode too, where it searches the release's code path rather than only what
  is loaded. Anything it cannot classify — including a probe that fails —
  comes back `:unknown` rather than being folded into either real answer.
  """
  @spec code_locations(node(), [module()], keyword()) ::
          {:ok, %{optional(module()) => :not_loaded | :absent | :unknown}} | {:error, term()}
  def code_locations(target_node, modules, opts \\ [])

  def code_locations(_target_node, [], _opts), do: {:ok, %{}}

  def code_locations(target_node, modules, opts) when is_atom(target_node) and is_list(modules) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    deadline = System.monotonic_time(:millisecond) + timeout

    requests =
      Enum.map(modules, fn mod ->
        {mod, :erpc.send_request(target_node, :code, :which, [mod])}
      end)

    Enum.reduce_while(requests, {:ok, %{}}, fn {mod, request_id}, {:ok, acc} ->
      case await_which(request_id, deadline) do
        {:ok, location} -> {:cont, {:ok, Map.put(acc, mod, location)}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  catch
    kind, reason -> {:error, {:unreachable, target_node, {kind, reason}}}
  end

  defp await_which(request_id, deadline) do
    try do
      case :erpc.receive_response(request_id, {:abs, deadline}) do
        :non_existing -> {:ok, :absent}
        path when is_list(path) -> {:ok, :not_loaded}
        # :preloaded and :cover_compiled are atoms, not paths — the module
        # is there but came from somewhere a push cannot be compared against.
        other when is_atom(other) -> {:ok, :unknown}
      end
    catch
      :error, {:erpc, :timeout} -> {:error, :timeout}
      :exit, {:erpc, :timeout} -> {:error, :timeout}
      :error, {:erpc, :noconnection} -> {:error, :noconnection}
      :exit, {:erpc, :noconnection} -> {:error, :noconnection}
      :error, {:erpc, reason} -> {:error, {:erpc, reason}}
      :exit, {:erpc, reason} -> {:error, {:erpc, reason}}
      _kind, _reason -> {:ok, :unknown}
    end
  end

  # -------------------------------------------------------------------
  # Push
  # -------------------------------------------------------------------

  @doc """
  Load `entries` onto `target_node`, module by module, refusing anything
  unsafe.

  Returns per-module outcomes:

    * `loaded` — `:code.load_binary/3` succeeded.
    * `skipped_identical` — the node already runs this exact md5.
    * `wedged` — `:code.soft_purge/1` returned `false` (processes are still
      running the module's old code). NOTHING was loaded for these; forcing
      it would strand those processes on a third generation and kill them.
    * `errors` — anything else, as operator-readable strings.

  Options:

    * `:allow_erts_mismatch` (default `false`) — proceed despite an ERTS
      version difference between here and the target.
    * `:skip_identical` (default `true`)
    * `:include_self` (default `true`) — whether to push this module itself.
      When included it is always pushed LAST.
    * `:timeout` (default `#{@default_timeout}`)
  """
  @spec push([entry()], node(), keyword()) :: {:ok, push_report()} | {:error, term()}
  def push(entries, target_node, opts \\ []) when is_list(entries) and is_atom(target_node) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    skip_identical? = Keyword.get(opts, :skip_identical, true)

    payload = payload_order(entries, Keyword.get(opts, :include_self, true))

    with :ok <- erts_gate(target_node, Keyword.get(opts, :allow_erts_mismatch, false), timeout),
         {:ok, remote} <- payload_remote_md5s(payload, target_node, skip_identical?, timeout) do
      report =
        Enum.reduce(payload, empty_report(), fn entry, report ->
          if skip_identical? and Map.get(remote, entry.module) == entry.md5 do
            %{report | skipped_identical: [entry.module | report.skipped_identical]}
          else
            load_one(entry, target_node, timeout, report)
          end
        end)

      {:ok,
       %{
         loaded: Enum.reverse(report.loaded),
         skipped_identical: Enum.reverse(report.skipped_identical),
         wedged: Enum.reverse(report.wedged),
         errors: Enum.reverse(report.errors)
       }}
    end
  end

  defp empty_report, do: %{loaded: [], skipped_identical: [], wedged: [], errors: []}

  defp payload_remote_md5s(_payload, _node, false, _timeout), do: {:ok, %{}}

  defp payload_remote_md5s(payload, target_node, true, timeout),
    do: remote_md5s(target_node, Enum.map(payload, & &1.module), timeout)

  # Drops excluded modules defensively (a caller may have hand-built the
  # payload) and moves this module to the very end — see the moduledoc.
  @doc false
  @spec payload_order([entry()], boolean()) :: [entry()]
  def payload_order(entries, include_self?) do
    {mine, others} =
      entries
      |> Enum.reject(&(&1.module in @excluded_modules))
      |> Enum.split_with(&(&1.module == __MODULE__))

    if include_self?, do: others ++ mine, else: others
  end

  defp erts_gate(target_node, allow_mismatch?, timeout) do
    case compatible?(target_node, min(timeout, @erts_probe_timeout)) do
      :ok ->
        :ok

      {:error, {:erts_mismatch, local, remote}} = error ->
        if allow_mismatch? do
          Logger.warning(
            "CodeSync: pushing to #{target_node} despite ERTS mismatch " <>
              "(local #{local}, remote #{remote}) — allow_erts_mismatch: true"
          )

          :ok
        else
          error
        end

      {:error, _} = error ->
        error
    end
  end

  defp load_one(entry, target_node, timeout, report) do
    %{module: mod, binary: binary, path: path} = entry

    try do
      # soft_purge NEVER kills a process: it returns false and does nothing
      # when any process still runs this module's old code. Honour that —
      # loading anyway is the documented route to a third code version.
      case :erpc.call(target_node, :code, :soft_purge, [mod], timeout) do
        false ->
          %{report | wedged: [mod | report.wedged]}

        true ->
          case :erpc.call(target_node, :code, :load_binary, [mod, path, binary], timeout) do
            {:module, ^mod} ->
              %{report | loaded: [mod | report.loaded]}

            {:error, reason} ->
              %{
                report
                | errors: ["#{inspect(mod)}: load failed - #{inspect(reason)}" | report.errors]
              }

            other ->
              %{
                report
                | errors: [
                    "#{inspect(mod)}: unexpected load result - #{inspect(other)}" | report.errors
                  ]
              }
          end

        other ->
          %{
            report
            | errors: [
                "#{inspect(mod)}: unexpected soft_purge result - #{inspect(other)}"
                | report.errors
              ]
          }
      end
    catch
      kind, reason ->
        %{report | errors: ["#{inspect(mod)}: #{kind} - #{inspect(reason)}" | report.errors]}
    end
  end

  @doc """
  Render an error term from `push/3`, `drift/2` or `compatible?/1` as a line
  an operator can act on.
  """
  @spec describe_error(term()) :: String.t()
  def describe_error({:erts_mismatch, local, remote}),
    do:
      "REFUSED: ERTS mismatch — this node compiles with erts-#{local}, target runs erts-#{remote}. " <>
        "Bytecode from a newer compiler is not supported on an older runtime; rebuild on a matching " <>
        "toolchain (see .tool-versions) or pass allow_erts_mismatch: true if you are certain."

  def describe_error({:unreachable, node, reason}),
    do: "REFUSED: #{node} unreachable — #{inspect(reason)}"

  def describe_error({:unreadable_dir, dir, reason}),
    do: "could not read ebin directory #{dir} — #{inspect(reason)}"

  def describe_error({:unreadable, path, reason}),
    do: "could not read #{path} — #{inspect(reason)}"

  def describe_error({:bad_beam, path, reason}),
    do: "#{path} is not a readable beam — #{inspect(reason)}"

  def describe_error(:timeout), do: "REFUSED: timed out talking to the target node"
  def describe_error(:noconnection), do: "REFUSED: lost connection to the target node"
  def describe_error(other), do: inspect(other)

  # -------------------------------------------------------------------
  # Fan-out convenience (Settings LiveView call sites)
  # -------------------------------------------------------------------

  @doc "Push everything this node is running to all remote nodes."
  def push_all(opts \\ []), do: push_dir(default_ebin_dir(), Node.list(), opts)

  @doc """
  Push only what actually differs.

  Differencing is by module md5, not file mtime: mtimes reset on every
  rebuild (a freshly built directory has nothing BUT new mtimes) and the old
  `:persistent_term` watermark reset on every restart, so mtime answered the
  wrong question in both directions. `push/3` already skips md5-identical
  modules, so this is `push_all/0` plus a "nothing to do" note.
  """
  def push_changed(opts \\ []) do
    result = push_all(opts)

    if result.modules_pushed == 0 and result.errors == [] do
      Map.put(result, :skipped, "no changed modules")
    else
      result
    end
  end

  @doc "Push all beams to a specific node."
  def push_to(target_node, opts \\ []) when is_atom(target_node),
    do: push_dir(default_ebin_dir(), [target_node], opts)

  @doc """
  Push a payload read from an arbitrary ebin directory (e.g. a freshly
  compiled `_build/prod/lib/orca_hub/ebin`) to `target_nodes`.
  """
  def push_dir(dir, target_nodes \\ nil, opts \\ []) do
    target_nodes = target_nodes || Node.list()

    case load_beams(dir) do
      {:ok, entries} ->
        push_to_nodes(entries, target_nodes, opts)

      {:error, reason} ->
        %{
          nodes_updated: 0,
          modules_pushed: 0,
          modules: [],
          errors: [describe_error(reason)],
          node_results: %{}
        }
    end
  end

  @doc "Push specific modules by name to all remote nodes."
  def push_modules(modules, target_nodes \\ nil, opts \\ []) when is_list(modules) do
    target_nodes = target_nodes || Node.list()

    entries =
      Enum.flat_map(modules, fn mod ->
        with {^mod, binary, filename} <- :code.get_object_code(mod),
             {:ok, {^mod, md5}} <- :beam_lib.md5(binary) do
          [%{module: mod, binary: binary, md5: md5, path: filename}]
        else
          _ -> []
        end
      end)

    push_to_nodes(entries, target_nodes, opts)
  end

  # Aggregates per-node reports into the flat summary the Settings LiveView
  # renders, while keeping the structured per-node detail under :node_results
  # for callers that want it. Wedged modules are folded into :errors so an
  # operator sees them without a UI change — they are not success.
  defp push_to_nodes(entries, [], _opts) do
    %{
      nodes_updated: 0,
      modules_pushed: length(entries),
      modules: Enum.map(entries, & &1.module),
      errors: ["no remote nodes connected"],
      node_results: %{}
    }
  end

  defp push_to_nodes(entries, target_nodes, opts) do
    results = Map.new(target_nodes, fn n -> {n, push(entries, n, opts)} end)

    errors =
      Enum.flat_map(results, fn
        {n, {:ok, report}} ->
          Enum.map(report.wedged, fn mod ->
            "#{n}: WEDGED #{inspect(mod)} — processes are still running its old code; " <>
              "refused (nothing was loaded for it)"
          end) ++ Enum.map(report.errors, &"#{n}: #{&1}")

        {n, {:error, reason}} ->
          ["#{n}: #{describe_error(reason)}"]
      end)

    loaded =
      results
      |> Enum.flat_map(fn
        {_n, {:ok, report}} -> report.loaded
        {_n, {:error, _}} -> []
      end)
      |> Enum.uniq()
      |> Enum.sort()

    ok_nodes = Enum.count(results, &match?({_, {:ok, _}}, &1))

    %{
      nodes_updated: ok_nodes,
      modules_pushed: length(loaded),
      modules: loaded,
      errors: errors,
      node_results: results
    }
  end

  # -------------------------------------------------------------------
  # Inspection
  # -------------------------------------------------------------------

  @doc "Get info about code versions on each node for a given module."
  def module_info_across_nodes(module) do
    nodes = [node() | Node.list()]

    Enum.map(nodes, fn n ->
      md5 =
        try do
          # Use :erlang.get_module_info/2 instead of :code.module_md5/1 because
          # the latter only works in embedded mode (releases), not interactive mode (mix).
          :erpc.call(n, :erlang, :get_module_info, [module, :md5], 5_000)
          |> Base.encode16(case: :lower)
        catch
          _, _ -> "unavailable"
        end

      %{node: n, module: module, md5: md5}
    end)
  end

  @doc """
  Check which modules differ between this node and remote nodes.

  The raw, pre-generation view: it compares against THIS node's build,
  reports `missing` without distinguishing "absent" from "not loaded", and
  cannot see the hub's desired generation, orphaned modules, or what code a
  node is actually running. `OrcaHub.Cluster.FleetStatus.report/1` answers
  all of those and is what the Settings page renders; prefer it for
  anything an operator reads.
  """
  def check_drift(dir \\ nil) do
    case load_beams(dir || default_ebin_dir()) do
      {:ok, entries} ->
        Enum.map(Node.list(), fn n ->
          base = %{
            node: n,
            drifted: [],
            missing: [],
            identical: [],
            total_checked: length(entries)
          }

          case drift(entries, n) do
            {:ok, report} -> Map.merge(base, report)
            {:error, reason} -> Map.put(base, :error, describe_error(reason))
          end
        end)

      {:error, reason} ->
        Logger.warning("CodeSync.check_drift: #{describe_error(reason)}")
        []
    end
  end

  # -------------------------------------------------------------------
  # Supervisor restart
  # -------------------------------------------------------------------

  @doc "Restart a named supervisor on a remote node (and all its children)."
  def restart_supervisor(target_node, supervisor_name) do
    try do
      # Find the supervisor's parent
      case :erpc.call(target_node, Process, :whereis, [supervisor_name], 10_000) do
        nil ->
          {:error, "#{supervisor_name} not found on #{target_node}"}

        pid ->
          # Get the parent supervisor and child id
          case :erpc.call(target_node, Process, :info, [pid, :dictionary], 10_000) do
            {:dictionary, dict} ->
              case List.keyfind(dict, :"$ancestors", 0) do
                {:"$ancestors", [parent | _]} ->
                  parent_pid =
                    if is_atom(parent),
                      do: :erpc.call(target_node, Process, :whereis, [parent], 10_000),
                      else: parent

                  # Terminate and restart under the parent
                  :erpc.call(
                    target_node,
                    Supervisor,
                    :terminate_child,
                    [parent_pid, supervisor_name],
                    10_000
                  )

                  :erpc.call(
                    target_node,
                    Supervisor,
                    :restart_child,
                    [parent_pid, supervisor_name],
                    10_000
                  )

                _ ->
                  {:error, "Could not determine parent supervisor for #{supervisor_name}"}
              end

            _ ->
              {:error, "Could not inspect process dictionary for #{supervisor_name}"}
          end
      end
    catch
      kind, reason ->
        {:error, "#{kind}: #{inspect(reason)}"}
    end
  end
end
