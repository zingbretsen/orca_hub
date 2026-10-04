defmodule OrcaHub.MemoryExtraction.DispatchHooksTest do
  use OrcaHub.DataCase, async: true

  import OrcaHub.MemoryExtractionStub

  alias OrcaHub.MemoryExtraction
  alias OrcaHub.MemoryExtraction.DispatchHooks
  alias OrcaHub.Sessions

  defp create_session! do
    {:ok, session} = Sessions.create_session(%{directory: "/tmp/dispatch-hooks-test"})
    session
  end

  # Runs `fun` the way a concurrently running sibling test would: in its own
  # process, with no link or `$callers` back to this one, sharing only this
  # test's sandbox connection so it can see the sessions created here.
  defp as_sibling_test(fun) do
    {pid, ref} = spawn_monitor(fn -> receive(do: (:go -> fun.())) end)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    send(pid, :go)
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 5_000
  end

  test "ORCAHUB3-133: a sibling test archiving its own session never reaches this test's hook" do
    own = create_session!()
    foreign = create_session!()
    stub_memory_extraction_dispatch(own)

    as_sibling_test(fn -> {:ok, _} = Sessions.archive_session(foreign) end)

    foreign_id = foreign.id
    refute_receive {:memory_extraction_dispatched, ^foreign_id, _}, 200
  end

  test "a sibling test's own hook, and its exit, leave this test's hook in place" do
    own = create_session!()
    foreign = create_session!()
    stub_memory_extraction_dispatch(own)

    as_sibling_test(fn ->
      stub_memory_extraction_dispatch(foreign)
      {:ok, _} = Sessions.archive_session(foreign)
      foreign_id = foreign.id
      assert_receive {:memory_extraction_dispatched, ^foreign_id, _}, 500
    end)

    {:ok, _} = Sessions.archive_session(own)

    own_id = own.id
    assert_receive {:memory_extraction_dispatched, ^own_id, [trigger: :archive]}, 500
  end

  test "a session's hook fires whichever process archives it (an erpc or Task hop has no $callers)" do
    own = create_session!()
    stub_memory_extraction_dispatch(own)

    as_sibling_test(fn -> {:ok, _} = Sessions.archive_session(own) end)

    own_id = own.id
    assert_receive {:memory_extraction_dispatched, ^own_id, [trigger: :archive]}, 500
  end

  test "an unhooked session gets the real dispatch" do
    assert DispatchHooks.dispatch_fun(Ecto.UUID.generate()) == (&MemoryExtraction.dispatch/2)
  end
end
