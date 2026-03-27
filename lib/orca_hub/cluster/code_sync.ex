defmodule OrcaHub.Cluster.CodeSync do
  @moduledoc """
  Hot code push: loads compiled .beam files from this node onto remote nodes.

  Only pushes beams from the `:orca_hub` application (not dependencies).
  Uses Erlang's `:code.load_binary/3` on remote nodes via `:erpc`.
  """

  require Logger

  @app :orca_hub
  @pt_key {__MODULE__, :last_push_at}

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc "Push all application beam files to all remote nodes."
  def push_all do
    beams = load_all_beams()
    push_to_nodes(beams, Node.list())
  end

  @doc "Push beam files modified since the last push."
  def push_changed do
    since = last_push_at()
    beams = load_changed_beams(since)

    if beams == [] do
      %{nodes_updated: 0, modules_pushed: 0, errors: [], skipped: "no changed modules"}
    else
      push_to_nodes(beams, Node.list())
    end
  end

  @doc "Push specific modules by name to all remote nodes."
  def push_modules(modules) when is_list(modules) do
    beams =
      Enum.flat_map(modules, fn mod ->
        case :code.get_object_code(mod) do
          {^mod, binary, filename} -> [{mod, binary, filename}]
          :error -> []
        end
      end)

    push_to_nodes(beams, Node.list())
  end

  @doc "Push all beams to a specific node."
  def push_to(target_node) when is_atom(target_node) do
    beams = load_all_beams()
    push_to_nodes(beams, [target_node])
  end

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
                  :erpc.call(target_node, Supervisor, :terminate_child, [parent_pid, supervisor_name], 10_000)
                  :erpc.call(target_node, Supervisor, :restart_child, [parent_pid, supervisor_name], 10_000)

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

  @doc "Get info about code versions on each node for a given module."
  def module_info_across_nodes(module) do
    nodes = [node() | Node.list()]

    Enum.map(nodes, fn n ->
      md5 =
        try do
          # Use :erlang.get_module_info/2 instead of :code.module_md5/1 because
          # the latter only works in embedded mode (releases), not interactive mode (mix).
          :erpc.call(n, :erlang, :get_module_info, [module, :md5], 5_000) |> Base.encode16(case: :lower)
        catch
          _, _ -> "unavailable"
        end

      %{node: n, module: module, md5: md5}
    end)
  end

  @doc "Check which modules differ between this node and remote nodes."
  def check_drift do
    local_beams = load_all_beams()
    # Use module_info(:md5) for local comparison - this is the MD5 embedded at compile time,
    # which matches what we'll get from the remote node. Using :erlang.md5(binary) would give
    # a different value (hash of entire .beam file vs just the module metadata).
    local_md5s = Map.new(local_beams, fn {mod, _binary, _} -> {mod, mod.module_info(:md5)} end)

    Enum.map(Node.list(), fn n ->
      drifted =
        Enum.filter(local_md5s, fn {mod, local_md5} ->
          remote_md5 =
            try do
              :erpc.call(n, :erlang, :get_module_info, [mod, :md5], 5_000)
            catch
              _, _ -> nil
            end

          remote_md5 != nil and remote_md5 != local_md5
        end)
        |> Enum.map(fn {mod, _} -> mod end)

      missing =
        Enum.filter(local_md5s, fn {mod, _} ->
          try do
            :erpc.call(n, :erlang, :get_module_info, [mod, :md5], 5_000)
          catch
            _, _ -> :missing
          end == :missing
        end)
        |> Enum.map(fn {mod, _} -> mod end)

      %{node: n, drifted: drifted, missing: missing, total_checked: map_size(local_md5s)}
    end)
  end

  # -------------------------------------------------------------------
  # Internal
  # -------------------------------------------------------------------

  defp load_all_beams do
    ebin_dir = Application.app_dir(@app, "ebin")

    ebin_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".beam"))
    |> Enum.map(fn file ->
      path = Path.join(ebin_dir, file)
      mod = file |> String.trim_trailing(".beam") |> String.to_existing_atom()
      binary = File.read!(path)
      {mod, binary, to_charlist(path)}
    end)
  end

  defp load_changed_beams(since) do
    ebin_dir = Application.app_dir(@app, "ebin")

    ebin_dir
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".beam"))
    |> Enum.flat_map(fn file ->
      path = Path.join(ebin_dir, file)
      %{mtime: mtime} = File.stat!(path, time: :posix)

      if mtime > since do
        mod = file |> String.trim_trailing(".beam") |> String.to_existing_atom()
        binary = File.read!(path)
        [{mod, binary, to_charlist(path)}]
      else
        []
      end
    end)
  end

  defp push_to_nodes(beams, target_nodes) do
    if target_nodes == [] do
      %{nodes_updated: 0, modules_pushed: length(beams), errors: ["no remote nodes connected"]}
    else
      results =
        Enum.map(target_nodes, fn n ->
          node_result = push_beams_to_node(beams, n)
          {n, node_result}
        end)

      errors =
        Enum.flat_map(results, fn {n, {:ok, errs}} ->
          Enum.map(errs, fn e -> "#{n}: #{e}" end)
        end)

      update_push_time()

      %{
        nodes_updated: length(target_nodes),
        modules_pushed: length(beams),
        modules: Enum.map(beams, fn {mod, _, _} -> mod end),
        errors: errors
      }
    end
  end

  defp push_beams_to_node(beams, target_node) do
    errors =
      Enum.flat_map(beams, fn {mod, binary, filename} ->
        try do
          # Purge old code if present (soft_purge won't kill running processes)
          :erpc.call(target_node, :code, :soft_purge, [mod], 10_000)
          # Load the new code
          case :erpc.call(target_node, :code, :load_binary, [mod, filename, binary], 10_000) do
            {:module, ^mod} -> []
            {:error, reason} -> ["#{mod}: load failed - #{inspect(reason)}"]
          end
        catch
          kind, reason ->
            ["#{mod}: #{kind} - #{inspect(reason)}"]
        end
      end)

    {:ok, errors}
  end

  defp last_push_at do
    try do
      :persistent_term.get(@pt_key)
    rescue
      ArgumentError -> 0
    end
  end

  defp update_push_time do
    :persistent_term.put(@pt_key, System.os_time(:second))
  end
end
