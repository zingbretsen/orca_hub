defmodule OrcaHub.Backend.SharedPromptsActiveSessionsTest do
  @moduledoc """
  `SharedPrompts.active_sessions_prompt/3` — the file-conflict signal a fresh
  orchestrator lands with: which OTHER sessions are currently active in its
  own working directory, and how to look them up itself. Separate file from
  `shared_prompts_test.exs` because this fragment does a real (indexed) DB
  read, so it needs `OrcaHub.DataCase`'s sandbox — every other fragment in
  that file is pure.
  """

  use OrcaHub.DataCase, async: true

  alias OrcaHub.Backend.SharedPrompts
  alias OrcaHub.Sessions

  defp dir, do: "/tmp/active_sessions_prompt_test_#{System.unique_integer([:positive])}"

  defp session!(dir, attrs \\ %{}) do
    {:ok, session} = Sessions.create_session(Map.merge(%{directory: dir}, attrs))
    session
  end

  defp backdate!(session, hours_ago) do
    updated_at =
      NaiveDateTime.utc_now()
      |> NaiveDateTime.truncate(:second)
      |> NaiveDateTime.add(-hours_ago * 3600, :second)

    session
    |> Ecto.Changeset.change(updated_at: updated_at)
    |> Repo.update!()
  end

  describe "active_sessions_prompt/3 — nil convention" do
    test "nil when session_id is nil" do
      assert SharedPrompts.active_sessions_prompt(nil, dir(), false) == nil
    end

    test "nil when there are no other sessions in the directory" do
      d = dir()
      self = session!(d)

      assert SharedPrompts.active_sessions_prompt(self.id, d, false) == nil
    end
  end

  describe "active_sessions_prompt/3 — scoping" do
    test "excludes the caller's own session" do
      d = dir()
      self = session!(d, %{orchestrator: true})

      assert SharedPrompts.active_sessions_prompt(self.id, d, false) == nil
    end

    test "excludes archived sessions" do
      d = dir()
      self = session!(d)
      session!(d, %{archived_at: DateTime.utc_now() |> DateTime.truncate(:second)})

      assert SharedPrompts.active_sessions_prompt(self.id, d, false) == nil
    end

    test "excludes background kinds (e.g. memory_extraction)" do
      d = dir()
      self = session!(d)
      session!(d, %{kind: "memory_extraction"})

      assert SharedPrompts.active_sessions_prompt(self.id, d, false) == nil
    end

    test "excludes sessions in a different directory" do
      self = session!(dir())
      session!(dir())

      assert SharedPrompts.active_sessions_prompt(self.id, self.directory, false) == nil
    end

    test "excludes an idle session outside the recency window" do
      d = dir()
      self = session!(d)
      stale = session!(d, %{status: "idle"})
      backdate!(stale, 48)

      assert SharedPrompts.active_sessions_prompt(self.id, d, false) == nil
    end

    test "includes a running session regardless of age" do
      d = dir()
      self = session!(d)
      old_running = session!(d, %{status: "running"})
      backdate!(old_running, 48)

      prompt = SharedPrompts.active_sessions_prompt(self.id, d, false)
      assert prompt =~ old_running.id
    end

    test "includes a waiting session regardless of age" do
      d = dir()
      self = session!(d)
      old_waiting = session!(d, %{status: "waiting"})
      backdate!(old_waiting, 48)

      prompt = SharedPrompts.active_sessions_prompt(self.id, d, false)
      assert prompt =~ old_waiting.id
    end

    test "includes an idle session inside the recency window" do
      d = dir()
      self = session!(d)
      recent_idle = session!(d, %{status: "idle"})

      prompt = SharedPrompts.active_sessions_prompt(self.id, d, false)
      assert prompt =~ recent_idle.id
    end
  end

  describe "active_sessions_prompt/3 — rendering" do
    test "lists peer id, title, status, orchestrator flag, and parent" do
      d = dir()
      self = session!(d)
      parent = session!(d)

      peer =
        session!(d, %{
          title: "worker fixing widgets",
          status: "idle",
          orchestrator: true,
          parent_session_id: parent.id,
          progress_phase: "implementing",
          progress_note: "writing tests"
        })

      prompt = SharedPrompts.active_sessions_prompt(self.id, d, false)

      assert prompt =~ "# Active Sessions In This Directory"
      assert prompt =~ peer.id
      assert prompt =~ "worker fixing widgets"
      assert prompt =~ "idle"
      assert prompt =~ "[orchestrator]"
      assert prompt =~ "parent: #{parent.id}"
      assert prompt =~ "implementing: writing tests"
    end

    test "a session with no parent shows \"root\"" do
      d = dir()
      self = session!(d)
      peer = session!(d)

      prompt = SharedPrompts.active_sessions_prompt(self.id, d, false)
      assert prompt =~ "#{peer.id} \"(untitled)\" (ready, parent: root)"
    end

    test "orchestrators are listed before non-orchestrators regardless of recency" do
      d = dir()
      self = session!(d)
      _worker = session!(d, %{title: "a worker"})
      orchestrator = session!(d, %{title: "an orchestrator", orchestrator: true})
      # Worker updated more recently than the orchestrator.
      backdate!(orchestrator, 1)

      prompt = SharedPrompts.active_sessions_prompt(self.id, d, false)

      assert prompt =~ ~r/an orchestrator.*a worker/s
      refute prompt =~ ~r/a worker.*an orchestrator/s
    end

    test "caps the listing and notes how many more" do
      d = dir()
      self = session!(d)
      for i <- 1..20, do: session!(d, %{title: "peer #{i}"})

      prompt = SharedPrompts.active_sessions_prompt(self.id, d, false)

      assert prompt =~ "and 5 more"
    end

    test "non-code-exec: points at the standalone search_sessions/get_session_tail/send_message_to_session MCP tools" do
      d = dir()
      self = session!(d)
      session!(d)

      prompt = SharedPrompts.active_sessions_prompt(self.id, d, false)

      assert prompt =~ "the `mcp__orca__search_sessions` MCP tool with no arguments"
      assert prompt =~ "`mcp__orca__get_session_tail`"
      assert prompt =~ "`mcp__orca__send_message_to_session`"
    end

    test "code_exec: points at the Tools.* functions inside run_elixir" do
      d = dir()
      self = session!(d)
      session!(d)

      prompt = SharedPrompts.active_sessions_prompt(self.id, d, true)

      assert prompt =~ "`Tools.search_sessions(%{})`"
      assert prompt =~ "`Tools.get_session_tail(...)`"
      assert prompt =~ "`Tools.send_message_to_session(...)`"
    end

    test "tells the orchestrator this worktree is shared and to check in about file ownership" do
      d = dir()
      self = session!(d)
      session!(d)

      prompt = SharedPrompts.active_sessions_prompt(self.id, d, false)

      assert prompt =~ "shared"
      assert prompt =~ "file"
    end
  end
end
