defmodule OrcaHub.MemoryReviewTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.{MemoryReview, Projects, Triggers}

  describe "consolidate_prompt/1" do
    test "defaults to a cap of 40 and mentions every allowed tool" do
      prompt = MemoryReview.consolidate_prompt()

      assert prompt =~ "at most 40 total actions"
      assert prompt =~ "Tools.merge_memories"
      assert prompt =~ "Tools.flag_memory"
      assert prompt =~ "Tools.verify_memories"
      assert prompt =~ "created_by\" => \"consolidation\""
    end

    test "a custom cap is reflected in the text" do
      prompt = MemoryReview.consolidate_prompt(%{cap: 7})
      assert prompt =~ "at most 7 total actions"
      refute prompt =~ "at most 40 total actions"
    end

    test "forbids retiring or rewriting an existing memory" do
      prompt = MemoryReview.consolidate_prompt()
      assert prompt =~ "NEVER call `retire_memory`"
      assert prompt =~ "NEVER call `update_memory` or"
    end

    test "bans the question tool and requires ending the turn" do
      prompt = MemoryReview.consolidate_prompt()
      assert prompt =~ "do not use the question/AskUserQuestion tool"
      assert prompt =~ "must end this turn when you are done"
    end

    test "names the pinned-memory and contradiction rules explicitly" do
      prompt = MemoryReview.consolidate_prompt()
      assert prompt =~ "Never touch a PINNED memory except to flag it"
      assert prompt =~ "do NOT merge them"
    end

    test "instructs saving a dated markdown artifact and a 3-line summary" do
      prompt = MemoryReview.consolidate_prompt()
      assert prompt =~ "memory-review-consolidate-<today's date, YYYY-MM-DD>"
      assert prompt =~ "\"kind\" => \"markdown\""
      assert prompt =~ "3-line summary"
    end

    test "is a pure function of opts (same opts, same output)" do
      assert MemoryReview.consolidate_prompt(%{cap: 12}) ==
               MemoryReview.consolidate_prompt(%{cap: 12})
    end
  end

  describe "verify_prompt/1" do
    test "defaults to a cap of 60 and mentions every allowed tool" do
      prompt = MemoryReview.verify_prompt()

      assert prompt =~ "#{60}"
      assert prompt =~ "Tools.verify_memories"
      assert prompt =~ "Tools.flag_memory"
      refute prompt =~ "Tools.merge_memories"
    end

    test "a custom cap is reflected in the text" do
      prompt = MemoryReview.verify_prompt(%{cap: 15})
      assert prompt =~ "\"per_page\" => 15"
    end

    test "scopes to this project + global/shared, never all_projects" do
      prompt = MemoryReview.verify_prompt()
      assert prompt =~ "do not call list_memories with all_projects: true"
      refute prompt =~ "\"all_projects\" => true"
    end

    test "forbids retiring or rewriting an existing memory" do
      prompt = MemoryReview.verify_prompt()
      assert prompt =~ "NEVER call `retire_memory`"
      assert prompt =~ "NEVER call `update_memory` or"
    end

    test "bans the question tool and requires ending the turn" do
      prompt = MemoryReview.verify_prompt()
      assert prompt =~ "do not use the question/AskUserQuestion tool"
      assert prompt =~ "must end this turn when you are done"
    end

    test "excludes pending extraction memories and describes the verification methods" do
      prompt = MemoryReview.verify_prompt()
      assert prompt =~ "created_by == \"extraction\""
      assert prompt =~ "review_status == \"pending\""
      assert prompt =~ "grep"
      assert prompt =~ "git cat-file -e"
      assert prompt =~ "curl -sI"
    end

    test "instructs saving a dated markdown artifact and a 3-line summary" do
      prompt = MemoryReview.verify_prompt()
      assert prompt =~ "memory-review-verify-<today's date, YYYY-MM-DD>"
      assert prompt =~ "\"kind\" => \"markdown\""
      assert prompt =~ "3-line summary"
    end

    test "is a pure function of opts (same opts, same output)" do
      assert MemoryReview.verify_prompt(%{cap: 5}) == MemoryReview.verify_prompt(%{cap: 5})
    end
  end

  describe "ensure_triggers!/1" do
    setup do
      dir = "/tmp/memory-review-test-#{System.unique_integer([:positive])}"

      {:ok, project} =
        Projects.create_project(%{name: "memory-review-test", directory: dir})

      %{dir: dir, project: project}
    end

    test "creates both triggers, upserted by name, with the required shape", %{
      dir: dir,
      project: project
    } do
      assert :ok = MemoryReview.ensure_triggers!(directory: dir)

      triggers = Triggers.list_triggers_for_project(project.id)
      names = Enum.map(triggers, & &1.name) |> Enum.sort()

      assert names == ["memory-consolidate-nightly", "memory-verify-weekly"]

      for trigger <- triggers do
        assert trigger.type == "scheduled"
        assert trigger.reuse_session == false
        assert trigger.archive_on_complete == true
        assert trigger.memory_extract == false
        assert trigger.enabled == true
      end

      consolidate = Enum.find(triggers, &(&1.name == "memory-consolidate-nightly"))
      assert consolidate.cron_expression == "0 3 * * *"
      assert consolidate.prompt == MemoryReview.consolidate_prompt()

      verify = Enum.find(triggers, &(&1.name == "memory-verify-weekly"))
      assert verify.cron_expression == "0 4 * * 0"
      assert verify.prompt == MemoryReview.verify_prompt()
    end

    test "is idempotent — running it again never duplicates", %{dir: dir, project: project} do
      assert :ok = MemoryReview.ensure_triggers!(directory: dir)
      assert :ok = MemoryReview.ensure_triggers!(directory: dir)
      assert :ok = MemoryReview.ensure_triggers!(directory: dir)

      assert length(Triggers.list_triggers_for_project(project.id)) == 2
    end

    test "restores a drifted prompt/cron on the next run", %{dir: dir, project: project} do
      assert :ok = MemoryReview.ensure_triggers!(directory: dir)

      [drifted | _] = Triggers.list_triggers_for_project(project.id)

      {:ok, _} =
        Triggers.update_trigger(drifted, %{
          prompt: "someone hand-edited this",
          cron_expression: "1 1 1 1 1"
        })

      assert :ok = MemoryReview.ensure_triggers!(directory: dir)

      restored = OrcaHub.HubRPC.get_trigger!(drifted.id)
      refute restored.prompt == "someone hand-edited this"
      refute restored.cron_expression == "1 1 1 1 1"
      assert length(Triggers.list_triggers_for_project(project.id)) == 2
    end

    test "is a no-op (not an error) when the project isn't registered yet" do
      assert :ok =
               MemoryReview.ensure_triggers!(
                 directory: "/tmp/no-such-project-#{System.unique_integer()}"
               )
    end
  end
end
