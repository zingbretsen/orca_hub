defmodule OrcaHub.MemoryExtractionStub do
  @moduledoc """
  Stubs memory-extraction dispatch for specific sessions, on top of
  `OrcaHub.MemoryExtraction.DispatchHooks`.

  Safe in `async: true` tests: only dispatches for the sessions passed here
  reach the calling test, and the stub goes away when that test's process
  exits. Every other session still gets the real
  `OrcaHub.MemoryExtraction.dispatch/2`, which is a skip in test because the
  memory service isn't configured.
  """

  alias OrcaHub.MemoryExtraction.DispatchHooks

  @doc """
  For each of `sessions` (structs or ids), a dispatch sends
  `{:memory_extraction_dispatched, session_id, opts}` to the calling process
  and returns `{:ok, :dispatched}` instead of running the real dispatch.
  Call it from the test process, or from `setup`, which runs there too.
  """
  def stub_memory_extraction_dispatch(sessions) do
    test_pid = self()

    for session <- List.wrap(sessions) do
      DispatchHooks.register(session_id(session), fn dispatched, opts ->
        send(test_pid, {:memory_extraction_dispatched, dispatched.id, opts})
        {:ok, :dispatched}
      end)
    end

    :ok
  end

  defp session_id(%{id: id}), do: id
  defp session_id(id) when is_binary(id), do: id
end
