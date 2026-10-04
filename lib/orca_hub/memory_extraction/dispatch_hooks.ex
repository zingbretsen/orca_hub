defmodule OrcaHub.MemoryExtraction.DispatchHooks do
  @moduledoc """
  Test seam for memory-extraction dispatch, keyed by session id.

  `OrcaHub.Sessions.archive_session/2` and the MCP `extract_memories` tool
  get their dispatch function from `dispatch_fun/1`: the hook registered for
  that session id, or else the real `OrcaHub.MemoryExtraction.dispatch/2`.

  The registry is started ONLY by `test/test_helper.exs`. Nothing starts it in
  prod or dev, so `dispatch_fun/1` costs one `Process.whereis/1` there and
  always returns the real dispatch.

  Why key on session id (ORCAHUB3-133): this used to be the global
  `:memory_extraction_dispatch_fun` app env, installed by `async: true`
  tests. Every concurrent test's archive dispatched into whichever hook was
  installed, and one test's `on_exit` `delete_env` could pull another test's
  hook out mid-test. A dispatch is about one session. Its id also survives
  every hop between the test and the dispatch (the `HubRPC`/`Cluster.rpc`
  `:erpc` call, the `Task.Supervisor` child), where `$callers` does not.

  A registration belongs to the process that made it, normally the test
  process, and disappears when that process exits. There is no cleanup to
  forget, and no cleanup that can remove another test's hook.
  """

  @registry __MODULE__

  @doc "Starts the hook registry. Test-only: called from `test/test_helper.exs`."
  def start_link, do: Registry.start_link(keys: :unique, name: @registry)

  @doc """
  Routes every dispatch for `session_id` to `fun` (same contract as
  `OrcaHub.MemoryExtraction.dispatch/2`) for as long as the calling process
  lives.
  """
  def register(session_id, fun) when is_binary(session_id) and is_function(fun, 2) do
    {:ok, _} = Registry.register(@registry, session_id, fun)
    :ok
  end

  @doc "The dispatch function for `session_id`: its registered hook, else the real dispatch."
  def dispatch_fun(session_id) do
    with pid when is_pid(pid) <- Process.whereis(@registry),
         [{_owner, fun}] <- Registry.lookup(@registry, session_id) do
      fun
    else
      _ -> &OrcaHub.MemoryExtraction.dispatch/2
    end
  end
end
