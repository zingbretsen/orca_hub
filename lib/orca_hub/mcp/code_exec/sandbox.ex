defmodule OrcaHub.MCP.CodeExec.Sandbox do
  @moduledoc """
  A lightweight custom evaluator for model-authored Elixir that may call the
  generated `Tools.*` functions and stitch results together with pure stdlib —
  but may **not** touch OrcaHub internals (Repo, contexts) or obviously-dangerous
  stdlib (System, File, Code, Port, ...).

  This is a SINGLE-USER platform: the goal is a clean allowlist that is *good
  enough*, not airtight. Determined bypasses via `apply/3`, `Module.concat/1`,
  `String.to_existing_atom |> :erlang.apply`, etc. are explicitly out of scope
  (see "Known gaps" below).

  ## How it works

  1. Parse with `Code.string_to_quoted/2` (preserving line metadata).
  2. Walk the AST (`Macro.prewalk`) and reject the snippet if it references any
     module **not** on the allowlist, or calls a denied local builtin. The
     allowlist is positive: only `@allowed_modules` plus the generated `Tools`
     namespace are permitted. Because it is an allowlist, anything under
     `OrcaHub.*` (and `System`, `File`, `:os`, ...) is rejected for free — but we
     also keep an explicit `@denied_modules` denylist so the rejection reason is
     precise and the intent is documented.
  3. Install the caller's MCP `state` in the eval process's dictionary (so the
     generated `Tools.*` functions can read it), redirect stdout to a capped
     `StringIO`, and evaluate inside a `Task` with a wall-clock timeout.

  ## Result tuples

    * `{:ok, %{value: term, stdout: binary}}`
    * `{:error, {:rejected, reason}}`   — failed parsing/allowlist (the model
      should FIX its code: syntax error, denied module)
    * `{:error, {:timeout, ms}}`        — ran too long (resource outcome)
    * `{:error, {:exception, %{banner: binary, line: integer | nil,
      stdout: binary}}}` — ran and raised/threw (a tool or expression outcome,
      e.g. `Tools.Error`); `banner` is trimmed of internal eval/Task frames and
      `line` points at the offending line of the snippet.

  ## Known gaps (acceptable for a single-user tool)

    * `apply/3`, `Module.concat/1` + dynamic atoms can reach denied modules at
      runtime — we block the obvious local builtins but not all dynamic-dispatch
      tricks.
    * No memory/reduction limit (only wall-clock + output-size caps).
  """

  require Logger

  alias OrcaHub.MCP.CodeExec

  # Pure stdlib we consider safe + helpful for stitching tool results.
  @allowed_modules ~w(
    Enum Stream Map MapSet Keyword List Tuple Range
    String Integer Float Kernel Function
    Jason Base URI Regex IO Inspect
    Date Time DateTime NaiveDateTime Calendar
    Access
  )a

  # Explicit denylist — redundant with the allowlist (these aren't allowed
  # anyway) but kept for precise error messages + documented intent.
  @denied_modules ~w(System File Code Port Node Process Task Agent GenServer Kernel.ParallelCompiler IO.ANSI)a
  @denied_erlang_modules ~w(os erlang file code init net_kernel rpc ets dets)a

  # Local builtins that enable dynamic dispatch / side effects.
  @denied_locals ~w(apply spawn spawn_link spawn_monitor send exit throw receive)a

  @default_timeout_ms 5_000
  @default_max_output 50_000

  # Synthetic file name attributed to the snippet's frames, so we can keep the
  # snippet's own line numbers and drop internal eval/Task plumbing frames.
  @snippet_file "run_elixir"

  @doc """
  Evaluate `code` (a string) in the sandbox.

  Options:

    * `:state`      — MCP state map installed in the eval process dictionary for
      the generated `Tools.*` functions to read (default `%{}`)
    * `:timeout_ms` — wall-clock timeout (default 5000)
    * `:max_output` — byte cap for captured stdout + formatted output
      (default 50_000)
  """
  def eval(code, opts \\ []) when is_binary(code) do
    timeout = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    max_output = Keyword.get(opts, :max_output, @default_max_output)
    state = Keyword.get(opts, :state, %{})

    with {:ok, ast} <- parse(code),
         :ok <- check(ast) do
      run(ast, state, timeout, max_output)
    else
      {:rejected, reason} -> {:error, {:rejected, reason}}
      {:error, {:rejected, _}} = err -> err
    end
  end

  # ── parse + static check ─────────────────────────────────────────────

  defp parse(code) do
    case Code.string_to_quoted(code, file: @snippet_file, columns: true) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {_meta, msg, token}} ->
        {:error, {:rejected, "syntax error: #{inspect(msg)} #{inspect(token)}"}}
    end
  end

  @doc """
  Statically validate an AST against the allowlist. Public so tests can assert
  on it directly without evaluating.
  """
  def check(ast) do
    Macro.prewalk(ast, :ok, fn node, acc -> {node, acc_check(node, acc)} end)
    |> elem(1)
  end

  # Once rejected, stay rejected (don't overwrite the first reason).
  defp acc_check(_node, {:rejected, _} = rejected), do: rejected

  # Aliased module reference: {:__aliases__, _, [:OrcaHub, :Repo]}
  defp acc_check({:__aliases__, _meta, parts}, :ok) when is_list(parts) do
    validate_module(parts)
  end

  # Erlang-style remote call: {{:., _, [:os, :cmd]}, _, args}
  defp acc_check({{:., _, [mod, _fun]}, _, _args}, :ok) when is_atom(mod) do
    if mod in @denied_erlang_modules do
      reject("erlang module :#{mod} is not allowed")
    else
      :ok
    end
  end

  # Local call: {:apply, _, [..]} — only when it's actually a call (args list).
  defp acc_check({name, _meta, args}, :ok) when is_atom(name) and is_list(args) do
    if name in @denied_locals do
      reject("local builtin `#{name}` is not allowed")
    else
      :ok
    end
  end

  defp acc_check(_node, acc), do: acc

  # First segment decides the namespace. `Tools.*` is the generated surface.
  defp validate_module([root | _] = parts) do
    cond do
      root == :Tools ->
        :ok

      root in @denied_modules ->
        reject("module #{Enum.join(parts, ".")} is denied")

      root in @allowed_modules ->
        :ok

      root == :OrcaHub ->
        reject(
          "OrcaHub.* internals are not accessible from the sandbox (#{Enum.join(parts, ".")})"
        )

      true ->
        reject("module #{Enum.join(parts, ".")} is not on the allowlist")
    end
  end

  defp reject(reason), do: {:rejected, reason}

  # ── evaluation ───────────────────────────────────────────────────────

  defp run(ast, state, timeout, max_output) do
    parent = self()
    ref = make_ref()

    task =
      Task.async(fn ->
        # Make the caller's MCP state visible to the generated Tools.* functions.
        CodeExec.put_state(state)

        # Redirect stdout (group leader) to an in-memory StringIO so we can
        # capture and cap it.
        {:ok, io} = StringIO.open("")
        Process.group_leader(self(), io)

        result =
          try do
            {value, _binding} = Code.eval_quoted(ast, [], eval_env())
            {:ok, value}
          rescue
            e -> {:raised, :error, e, __STACKTRACE__}
          catch
            kind, reason -> {:raised, kind, reason, __STACKTRACE__}
          end

        {_in, out} = StringIO.contents(io)
        StringIO.close(io)
        send(parent, {ref, result, out})
      end)

    receive do
      {^ref, result, out} ->
        Task.shutdown(task, :brutal_kill)
        finalize(result, out, max_output)
    after
      timeout ->
        Task.shutdown(task, :brutal_kill)
        {:error, {:timeout, timeout}}
    end
  end

  defp finalize({:ok, value}, out, max_output) do
    {:ok, %{value: value, stdout: cap(out, max_output)}}
  end

  defp finalize({:raised, kind, reason, trace}, out, max_output) do
    banner = Exception.format_banner(kind, reason)
    line = snippet_line(trace)

    {:error,
     {:exception, %{banner: cap(banner, max_output), line: line, stdout: cap(out, max_output)}}}
  end

  # The first stack frame attributed to the snippet — its line is the offending
  # line of the model's code. Internal eval/Task frames are skipped.
  defp snippet_line(trace) do
    Enum.find_value(trace, fn
      {_mod, _fun, _arity, loc} ->
        if loc[:file] && to_string(loc[:file]) == @snippet_file, do: loc[:line]

      _ ->
        nil
    end)
  end

  defp cap(bin, max) when byte_size(bin) > max do
    binary_part(bin, 0, max) <> "\n…[truncated #{byte_size(bin) - max} bytes]"
  end

  defp cap(bin, _max), do: bin

  # A minimal eval env. We deliberately do NOT auto-`import`/`alias` anything
  # beyond defaults — the allowlist check already gates module access, and the
  # generated `Tools` modules are referenced by their fully-qualified name. The
  # synthetic file name lets us recover the snippet's own line numbers.
  defp eval_env do
    %{__ENV__ | file: @snippet_file, function: nil}
  end
end
