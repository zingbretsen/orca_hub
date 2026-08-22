defmodule OrcaHub.Sessions.ChurnDetailTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Sessions
  alias OrcaHub.Sessions.ChurnDetail

  defp assistant_message(blocks) do
    %{data: %{"type" => "assistant", "message" => %{"content" => blocks}}}
  end

  defp tool_use(name, input) do
    %{"type" => "tool_use", "name" => name, "input" => input}
  end

  defp user_tool_result(content) do
    %{
      data: %{
        "type" => "user",
        "message" => %{"content" => [%{"type" => "tool_result", "content" => content}]}
      }
    }
  end

  describe "compute/1 — top_edited_files" do
    test "histograms Edit/Write/MultiEdit file_path inputs, ignores other tools, top 5" do
      messages = [
        assistant_message([tool_use("Edit", %{"file_path" => "lib/a.ex"})]),
        assistant_message([tool_use("Edit", %{"file_path" => "lib/a.ex"})]),
        assistant_message([tool_use("Write", %{"file_path" => "lib/b.ex"})]),
        assistant_message([tool_use("MultiEdit", %{"file_path" => "lib/c.ex"})]),
        assistant_message([tool_use("Bash", %{"command" => "ls"})])
      ]

      detail = ChurnDetail.compute(messages)

      assert detail.top_edited_files == [
               %{path: "lib/a.ex", count: 2},
               %{path: "lib/b.ex", count: 1},
               %{path: "lib/c.ex", count: 1}
             ]
    end

    test "returns [] when nothing was edited" do
      messages = [assistant_message([tool_use("Bash", %{"command" => "ls"})])]

      assert ChurnDetail.compute(messages).top_edited_files == []
    end

    test "never raises on a malformed input map (missing/non-string file_path)" do
      messages = [
        assistant_message([tool_use("Edit", %{})]),
        assistant_message([tool_use("Edit", %{"file_path" => 123})]),
        assistant_message([%{"type" => "tool_use", "name" => "Edit"}])
      ]

      assert ChurnDetail.compute(messages).top_edited_files == []
    end
  end

  describe "compute/1 — top_repeated_signatures" do
    test "only includes signatures that recurred 2+ times, sorted by count desc, capped at 3" do
      bash_call = tool_use("Bash", %{"command" => "mix test"})
      read_call = tool_use("Read", %{"file_path" => "lib/a.ex"})
      once_call = tool_use("Grep", %{"pattern" => "foo"})

      messages =
        List.duplicate(assistant_message([bash_call]), 4) ++
          List.duplicate(assistant_message([read_call]), 2) ++
          [assistant_message([once_call])]

      detail = ChurnDetail.compute(messages)

      assert [
               %{tool: "Bash", count: 4, sample: bash_sample},
               %{tool: "Read", count: 2, sample: read_sample}
             ] = detail.top_repeated_signatures

      assert bash_sample =~ "Bash"
      assert bash_sample =~ "mix test"
      assert read_sample =~ "Read"
    end

    test "returns [] when nothing repeated" do
      messages = [assistant_message([tool_use("Bash", %{"command" => "ls"})])]

      assert ChurnDetail.compute(messages).top_repeated_signatures == []
    end
  end

  describe "compute/1 — failing_tests" do
    test "extracts the mix-test summary and preceding failing test names, most recent first" do
      failing_content = """
        1) test does the thing (MyAppTest)
           ** (RuntimeError) boom

        2) test another thing (MyAppTest)
           ** (RuntimeError) boom2

      12 tests, 2 failures
      """

      passing_content = "8 tests, 0 failures\nall good"

      # Oldest-first input (as fetch/2 would hand compute/1) — the passing
      # run happened first, the failing run is the most recent.
      messages = [
        user_tool_result(passing_content),
        user_tool_result(failing_content)
      ]

      detail = ChurnDetail.compute(messages)

      assert [%{summary: summary, failing_test_names: names}] = detail.failing_tests
      assert summary =~ "12 tests, 2 failures"
      assert names == ["test does the thing (MyAppTest)", "test another thing (MyAppTest)"]
    end

    test "ignores a passing run (0 failures never matches)" do
      messages = [user_tool_result("8 tests, 0 failures")]

      assert ChurnDetail.compute(messages).failing_tests == []
    end

    test "caps at 3 entries and reads tool_result list-shaped content too" do
      list_shaped = [%{"type" => "text", "text" => "3 tests, 1 failure\n  1) test x (T)"}]

      messages =
        for content <- [
              "10 tests, 5 failures",
              "11 tests, 1 failures",
              "12 tests, 2 failures",
              list_shaped
            ] do
          user_tool_result(content)
        end

      detail = ChurnDetail.compute(messages)

      assert length(detail.failing_tests) == 3
      # Most-recent-first: the list-shaped (last inserted) entry comes first.
      assert hd(detail.failing_tests).summary =~ "3 tests, 1 failure"
    end
  end

  describe "compute/1 — never raises" do
    test "degrades to [] across the board for nonsense input" do
      messages = [%{data: %{"type" => "assistant", "message" => %{"content" => "not a list"}}}]

      assert ChurnDetail.compute(messages) == %{
               top_edited_files: [],
               top_repeated_signatures: [],
               failing_tests: []
             }
    end
  end

  describe "fetch/2" do
    defp fixture_session do
      dir =
        Path.join(System.tmp_dir!(), "churn-detail-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, session} = Sessions.create_session(%{directory: dir})
      session
    end

    test "reads real messages from the DB within the window" do
      session = fixture_session()

      {:ok, _} =
        Sessions.create_message(%{
          session_id: session.id,
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{"type" => "tool_use", "name" => "Edit", "input" => %{"file_path" => "lib/x.ex"}}
              ]
            }
          }
        })

      detail = ChurnDetail.fetch(session.id)

      assert detail.top_edited_files == [%{path: "lib/x.ex", count: 1}]
    end

    test "excludes messages older than the window" do
      session = fixture_session()

      {:ok, message} =
        Sessions.create_message(%{
          session_id: session.id,
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{"type" => "tool_use", "name" => "Edit", "input" => %{"file_path" => "lib/x.ex"}}
              ]
            }
          }
        })

      old = NaiveDateTime.utc_now() |> NaiveDateTime.add(-3600, :second)
      Sessions.Message.changeset(message, %{}) |> Ecto.Changeset.force_change(:inserted_at, old)

      OrcaHub.Repo.update_all(
        from(m in Sessions.Message, where: m.id == ^message.id),
        set: [inserted_at: old]
      )

      detail = ChurnDetail.fetch(session.id, window_minutes: 30)

      assert detail.top_edited_files == []
    end
  end
end
