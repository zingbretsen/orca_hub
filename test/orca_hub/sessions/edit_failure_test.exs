defmodule OrcaHub.Sessions.EditFailureTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Sessions
  alias OrcaHub.Sessions.EditFailure

  defp assistant_message(blocks) do
    %{data: %{"type" => "assistant", "message" => %{"content" => blocks}}}
  end

  defp user_message(blocks) do
    %{data: %{"type" => "user", "message" => %{"content" => blocks}}}
  end

  defp tool_use(id, name, input) do
    %{"type" => "tool_use", "id" => id, "name" => name, "input" => input}
  end

  defp tool_result(tool_use_id, opts) do
    %{
      "type" => "tool_result",
      "tool_use_id" => tool_use_id,
      "is_error" => Keyword.get(opts, :is_error, false),
      "content" => [%{"type" => "text", "text" => Keyword.get(opts, :text, "")}]
    }
  end

  # One failed/succeeded editor call: the assistant's tool_use followed by
  # the user message carrying its tool_result, exactly as the transcript
  # stores it.
  defp editor_call(id, name, input, opts) do
    [
      assistant_message([tool_use(id, name, input)]),
      user_message([tool_result(id, opts)])
    ]
  end

  defp failed_edit(id, path, opts \\ []) do
    input = %{
      "file_path" => path,
      "old_string" => Keyword.get(opts, :old_string, "foo"),
      "new_string" => Keyword.get(opts, :new_string, "bar")
    }

    editor_call(id, "Edit", input,
      is_error: true,
      text: Keyword.get(opts, :text, "String to replace not found in file.")
    )
  end

  defp successful_edit(id, path, opts \\ []) do
    input = %{
      "file_path" => path,
      "old_string" => Keyword.get(opts, :old_string, "foo"),
      "new_string" => Keyword.get(opts, :new_string, "bar")
    }

    editor_call(id, "Edit", input, is_error: false, text: "The file has been updated.")
  end

  describe "detect/1 — the threshold" do
    test "two failed Edits on one path fires" do
      messages = failed_edit("e1", "lib/foo.ex") ++ failed_edit("e2", "lib/foo.ex")

      evidence = EditFailure.detect(messages)
      assert evidence.path == "lib/foo.ex"
      assert evidence.failure_count == 2
      assert evidence.tools == ["Edit"]
      assert evidence.last_error == "String to replace not found in file."
    end

    test "ONE failure does not fire" do
      messages = failed_edit("e1", "lib/foo.ex")

      assert EditFailure.detect(messages) == nil
    end

    test "three failures report the full streak count" do
      messages =
        failed_edit("e1", "lib/foo.ex") ++
          failed_edit("e2", "lib/foo.ex") ++ failed_edit("e3", "lib/foo.ex")

      assert EditFailure.detect(messages).failure_count == 3
    end

    test "Write and MultiEdit failures count too, and are reported in tools" do
      messages =
        editor_call("w1", "Write", %{"file_path" => "lib/foo.ex", "content" => "x"},
          is_error: true,
          text: "EACCES"
        ) ++
          editor_call("m1", "MultiEdit", %{"file_path" => "lib/foo.ex", "edits" => []},
            is_error: true,
            text: "EACCES"
          )

      evidence = EditFailure.detect(messages)
      assert evidence.failure_count == 2
      assert evidence.tools == ["Write", "MultiEdit"]
    end

    test "successful calls alone never fire" do
      messages = successful_edit("e1", "lib/foo.ex") ++ successful_edit("e2", "lib/foo.ex")

      assert EditFailure.detect(messages) == nil
    end

    test "volume is irrelevant: two failures at four total tool calls fire" do
      messages =
        [assistant_message([tool_use("b1", "Bash", %{"command" => "ls"})])] ++
          [assistant_message([tool_use("r1", "Read", %{"file_path" => "lib/foo.ex"})])] ++
          failed_edit("e1", "lib/foo.ex") ++ failed_edit("e2", "lib/foo.ex")

      assert EditFailure.detect(messages).failure_count == 2
    end
  end

  describe "detect/1 — reset on success" do
    test "failure -> SUCCESS -> failure does NOT fire" do
      messages =
        failed_edit("e1", "lib/foo.ex") ++
          successful_edit("s1", "lib/foo.ex") ++ failed_edit("e2", "lib/foo.ex")

      assert EditFailure.detect(messages) == nil
    end

    test "an interleaved success resets the count, so only the later streak counts" do
      messages =
        failed_edit("e1", "lib/foo.ex") ++
          failed_edit("e2", "lib/foo.ex") ++
          successful_edit("s1", "lib/foo.ex") ++
          failed_edit("e3", "lib/foo.ex", text: "later failure") ++
          failed_edit("e4", "lib/foo.ex", text: "later failure")

      evidence = EditFailure.detect(messages)
      assert evidence.failure_count == 2
      assert evidence.last_error == "later failure"
    end

    test "a success on a DIFFERENT path does not reset the streak" do
      messages =
        failed_edit("e1", "lib/foo.ex") ++
          successful_edit("s1", "lib/other.ex") ++ failed_edit("e2", "lib/foo.ex")

      assert EditFailure.detect(messages).path == "lib/foo.ex"
    end
  end

  describe "detect/1 — paths do not combine" do
    test "one failure each on two DIFFERENT paths does not fire" do
      messages = failed_edit("e1", "lib/foo.ex") ++ failed_edit("e2", "lib/bar.ex")

      assert EditFailure.detect(messages) == nil
    end

    test "with two qualifying paths, the most recent streak is reported" do
      messages =
        failed_edit("e1", "lib/foo.ex") ++
          failed_edit("e2", "lib/foo.ex") ++
          failed_edit("e3", "lib/bar.ex") ++ failed_edit("e4", "lib/bar.ex")

      assert EditFailure.detect(messages).path == "lib/bar.ex"
    end
  end

  describe "detect/1 — identical_calls" do
    test "true when the failed calls are byte-identical" do
      messages = failed_edit("e1", "lib/foo.ex") ++ failed_edit("e2", "lib/foo.ex")

      assert EditFailure.detect(messages).identical_calls == true
    end

    test "false when the worker varied its attempts" do
      messages =
        failed_edit("e1", "lib/foo.ex", old_string: "alpha") ++
          failed_edit("e2", "lib/foo.ex", old_string: "beta")

      assert EditFailure.detect(messages).identical_calls == false
    end

    test "false when the worker escalated from Edit to Write" do
      messages =
        failed_edit("e1", "lib/foo.ex") ++
          editor_call("w1", "Write", %{"file_path" => "lib/foo.ex", "content" => "x"},
            is_error: true,
            text: "EACCES"
          )

      assert EditFailure.detect(messages).identical_calls == false
    end
  end

  describe "detect/1 — ORCAHUB3-63 motivating case" do
    test "two identical failed Edit calls attempting to CREATE a nonexistent file" do
      input = %{
        "file_path" => "lib/orca_hub/sessions/edit_failure.ex",
        "old_string" => "",
        "new_string" => "defmodule OrcaHub.Sessions.EditFailure do\nend\n"
      }

      error = "File does not exist. Use the Write tool to create a new file."

      messages =
        editor_call("c1", "Edit", input, is_error: true, text: error) ++
          editor_call("c2", "Edit", input, is_error: true, text: error)

      evidence = EditFailure.detect(messages)
      assert evidence.path == "lib/orca_hub/sessions/edit_failure.ex"
      assert evidence.failure_count == 2
      assert evidence.tools == ["Edit"]
      assert evidence.identical_calls == true
      assert evidence.last_error == error
    end
  end

  describe "detect/1 — result pairing" do
    test "a call whose result is missing is UNKNOWN: it neither counts nor resets" do
      # e1/e3 failed; the middle call has no tool_result at all, so it must
      # not be read as a success that clears the streak.
      messages =
        failed_edit("e1", "lib/foo.ex") ++
          [assistant_message([tool_use("e2", "Edit", %{"file_path" => "lib/foo.ex"})])] ++
          failed_edit("e3", "lib/foo.ex")

      evidence = EditFailure.detect(messages)
      assert evidence.failure_count == 2
    end

    test "a tool_result with no is_error key is a success and resets" do
      result = %{
        "type" => "tool_result",
        "tool_use_id" => "s1",
        "content" => "The file has been updated."
      }

      messages =
        failed_edit("e1", "lib/foo.ex") ++
          [
            assistant_message([tool_use("s1", "Edit", %{"file_path" => "lib/foo.ex"})]),
            user_message([result])
          ] ++ failed_edit("e2", "lib/foo.ex")

      assert EditFailure.detect(messages) == nil
    end

    test "a string tool_result content is read for the error text" do
      result = %{
        "type" => "tool_result",
        "tool_use_id" => "e2",
        "is_error" => true,
        "content" => "  String to replace not found in file.  "
      }

      messages =
        failed_edit("e1", "lib/foo.ex") ++
          [
            assistant_message([tool_use("e2", "Edit", %{"file_path" => "lib/foo.ex"})]),
            user_message([result])
          ]

      assert EditFailure.detect(messages).last_error == "String to replace not found in file."
    end

    test "last_error is nil when the failing result carries no readable text" do
      messages =
        failed_edit("e1", "lib/foo.ex") ++ failed_edit("e2", "lib/foo.ex", text: "")

      assert EditFailure.detect(messages).last_error == nil
    end

    test "last_error is trimmed to a bounded length" do
      messages =
        failed_edit("e1", "lib/foo.ex") ++
          failed_edit("e2", "lib/foo.ex", text: String.duplicate("x", 5_000))

      assert String.length(EditFailure.detect(messages).last_error) == 300
    end
  end

  describe "detect/1 — robustness" do
    test "returns nil on an empty message list" do
      assert EditFailure.detect([]) == nil
    end

    test "returns nil when nothing matches" do
      messages = [assistant_message([tool_use("b1", "Bash", %{"command" => "ls -la"})])]

      assert EditFailure.detect(messages) == nil
    end

    test "never raises on malformed content" do
      messages = [%{data: %{"type" => "assistant", "message" => %{"content" => "not a list"}}}]

      assert EditFailure.detect(messages) == nil
    end

    test "never raises on messages with no data at all" do
      assert EditFailure.detect([%{}, %{data: nil}, %{data: %{}}]) == nil
    end

    test "an editor call with no file_path is ignored rather than raising" do
      messages =
        [assistant_message([tool_use("e1", "Edit", %{"old_string" => "x"})])] ++
          [user_message([tool_result("e1", is_error: true)])] ++
          failed_edit("e2", "lib/foo.ex")

      assert EditFailure.detect(messages) == nil
    end

    test "rejects non-list input rather than raising" do
      assert EditFailure.detect(%{not: "a list"}) == nil
    end
  end

  describe "fetch/2" do
    defp fixture_session do
      dir =
        Path.join(System.tmp_dir!(), "edit-failure-test-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, session} = Sessions.create_session(%{directory: dir})
      session
    end

    defp persist!(session, data) do
      {:ok, message} = Sessions.create_message(%{session_id: session.id, data: data})
      message
    end

    defp persist_failed_edit!(session, id, path) do
      persist!(session, %{
        "type" => "assistant",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_use",
              "id" => id,
              "name" => "Edit",
              "input" => %{"file_path" => path, "old_string" => "a", "new_string" => "b"}
            }
          ]
        }
      })

      persist!(session, %{
        "type" => "user",
        "message" => %{
          "content" => [
            %{
              "type" => "tool_result",
              "tool_use_id" => id,
              "is_error" => true,
              "content" => [%{"type" => "text", "text" => "File does not exist."}]
            }
          ]
        }
      })
    end

    test "reads real messages from the DB within the window" do
      session = fixture_session()
      persist_failed_edit!(session, "e1", "lib/foo.ex")
      persist_failed_edit!(session, "e2", "lib/foo.ex")

      evidence = EditFailure.fetch(session.id)
      assert evidence.path == "lib/foo.ex"
      assert evidence.failure_count == 2
      assert evidence.identical_calls == true
    end

    test "excludes messages older than the window" do
      session = fixture_session()
      persist_failed_edit!(session, "e1", "lib/foo.ex")
      last = persist_failed_edit!(session, "e2", "lib/foo.ex")

      old = NaiveDateTime.utc_now() |> NaiveDateTime.add(-3600, :second)

      OrcaHub.Repo.update_all(
        from(m in Sessions.Message, where: m.session_id == ^session.id and m.id != ^last.id),
        set: [inserted_at: old]
      )

      assert EditFailure.fetch(session.id, window_minutes: 30) == nil
    end

    test "never raises on an invalid session_id, returns nil" do
      assert EditFailure.fetch("not-a-uuid") == nil
    end
  end

  describe "fetch_many/2" do
    test "every requested session_id is a key of the result, even with no messages" do
      session_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      result = EditFailure.fetch_many(session_ids)

      assert Map.keys(result) |> Enum.sort() == Enum.sort(session_ids)
      assert Enum.all?(session_ids, &(result[&1] == nil))
    end

    test "returns an empty map for an empty list" do
      assert EditFailure.fetch_many([]) == %{}
    end

    test "an invalid id is dropped before the query and still gets a nil key" do
      session = fixture_session()
      persist_failed_edit!(session, "e1", "lib/foo.ex")
      persist_failed_edit!(session, "e2", "lib/foo.ex")

      result = EditFailure.fetch_many(["not-a-uuid", session.id])

      assert Map.has_key?(result, "not-a-uuid")
      assert result["not-a-uuid"] == nil
      assert result[session.id].path == "lib/foo.ex"
    end

    test "batches evidence per session in one query" do
      session1 = fixture_session()
      session2 = fixture_session()

      persist_failed_edit!(session1, "e1", "lib/foo.ex")
      persist_failed_edit!(session1, "e2", "lib/foo.ex")
      persist_failed_edit!(session2, "e3", "lib/bar.ex")

      result = EditFailure.fetch_many([session1.id, session2.id])

      assert result[session1.id].path == "lib/foo.ex"
      assert result[session2.id] == nil
    end
  end
end
