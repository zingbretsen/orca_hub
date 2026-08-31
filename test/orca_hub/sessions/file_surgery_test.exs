defmodule OrcaHub.Sessions.FileSurgeryTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.Sessions
  alias OrcaHub.Sessions.FileSurgery

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

  defp bash(cmd), do: tool_use("t-bash", "Bash", %{"command" => cmd})

  describe "detect/1 — family :write_to_tracked" do
    test "shell redirection whose OUTPUT is a tracked path" do
      messages = [assistant_message([bash("echo 'junk' > lib/foo.ex")])]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "lib/foo.ex"
      assert evidence.kind == :write_to_tracked
    end

    test "cp INTO a tracked path fires" do
      messages = [assistant_message([bash("cp /tmp/scratch.ex lib/foo.ex")])]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "lib/foo.ex"
      assert evidence.kind == :write_to_tracked
    end

    test "mv INTO a tracked path fires" do
      messages = [assistant_message([bash("mv /tmp/new_foo.ex lib/foo.ex")])]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "lib/foo.ex"
      assert evidence.kind == :write_to_tracked
    end

    test "tee INTO a tracked path fires (piped form)" do
      messages = [assistant_message([bash("echo 'junk' | tee lib/foo.ex")])]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "lib/foo.ex"
      assert evidence.kind == :write_to_tracked
    end

    test "direction matters: cp FROM a tracked file to a .bak is benign, does not fire" do
      messages = [assistant_message([bash("cp lib/foo.ex lib/foo.ex.bak")])]

      assert FileSurgery.detect(messages) == nil
    end

    test "direction matters: cp FROM a .bak INTO the tracked file fires" do
      messages = [assistant_message([bash("cp lib/foo.ex.bak lib/foo.ex")])]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "lib/foo.ex"
      assert evidence.kind == :write_to_tracked
    end
  end

  describe "detect/1 — family :in_place_edit" do
    test "sed -i fires and names the tracked path" do
      messages = [assistant_message([bash("sed -i 's/foo/bar/' lib/foo.ex")])]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "lib/foo.ex"
      assert evidence.kind == :in_place_edit
    end

    test "perl -pi fires and names the tracked path" do
      messages = [assistant_message([bash("perl -pi -e 's/foo/bar/' lib/foo.ex")])]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "lib/foo.ex"
      assert evidence.kind == :in_place_edit
    end
  end

  describe "detect/1 — family :programmatic_write" do
    test "a mix run -e script containing File.write! on a tracked path fires" do
      messages = [
        assistant_message([
          bash("mix run --no-start -e 'File.write!(\"lib/foo.ex\", new_code)'")
        ])
      ]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "lib/foo.ex"
      assert evidence.kind == :programmatic_write
    end

    test "a python open(..., \"w\") on a tracked path fires" do
      messages = [
        assistant_message([bash("python3 -c \"open('lib/foo.ex', 'w').write(x)\"")])
      ]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "lib/foo.ex"
      assert evidence.kind == :programmatic_write
    end
  end

  describe "detect/1 — ORCAHUB3-61 regression fixture: the real qwen sed-i/File.write! incident" do
    test "the 3cd4a43c session's actual command sequence fires via a non-redirect family" do
      # Replayed in order from the live incident: worker read the file,
      # backed it up, ran two in-place sed edits, explored some more,
      # wrote a NEW scratch file (benign), rewrote it programmatically via
      # File.write!, then restored from its own backup (still a shell
      # write INTO the tracked file — direction matters, so this fires
      # too). Family D (slice-and-redirect) does NOT fire on this
      # sequence at all — neither sed -i nor the mix run -e rewrite use a
      # redirect operator, which is the whole point of the widening.
      messages = [
        assistant_message([bash("cat lib/orca_hub/sessions/churn.ex")]),
        assistant_message([
          bash("cp lib/orca_hub/sessions/churn.ex lib/orca_hub/sessions/churn.ex.bak")
        ]),
        assistant_message([
          bash(
            "sed -i 's/def assess(activity, session, commit_info, now \\\\ DateTime.utc_now())/def assess(activity, session, commit_info, now \\\\ DateTime.utc_now(), file_surgery \\\\ nil)/' lib/orca_hub/sessions/churn.ex"
          )
        ]),
        assistant_message([
          bash(
            "sed -i 's/def assess(activity, session, commit_info, now) do/def assess(activity, session, commit_info, now, file_surgery) do/' lib/orca_hub/sessions/churn.ex"
          )
        ]),
        assistant_message([
          bash("cat lib/orca_hub/sessions/churn.ex | grep -n \"churn_suspected\"")
        ]),
        assistant_message([bash("sed -n '77,86p' lib/orca_hub/sessions/churn.ex")]),
        assistant_message([bash("cat > /tmp/churn_patch.ex << 'EOF'\n# scratch\nEOF")]),
        assistant_message([
          bash(
            "mix run --no-start -e 'code = File.read!(\"lib/orca_hub/sessions/churn.ex\")\nFile.write!(\"lib/orca_hub/sessions/churn.ex\", new_code)\nIO.puts(\"Updated churn.ex\")\n'"
          )
        ]),
        assistant_message([
          bash("cp lib/orca_hub/sessions/churn.ex.bak lib/orca_hub/sessions/churn.ex")
        ])
      ]

      evidence = FileSurgery.detect(messages)

      # The MOST RECENT match is the final restore cp — still a shell
      # write into the tracked file, so it correctly fires too.
      assert evidence.path == "lib/orca_hub/sessions/churn.ex"
      assert evidence.kind == :write_to_tracked
      assert evidence.kind != :slice_and_redirect

      assert evidence.command ==
               "cp lib/orca_hub/sessions/churn.ex.bak lib/orca_hub/sessions/churn.ex"
    end
  end

  describe "detect/1 — widened exclusions" do
    test "mix format" do
      messages = [assistant_message([bash("mix format lib/foo.ex")])]
      assert FileSurgery.detect(messages) == nil
    end

    test "mix format --check-formatted" do
      messages = [assistant_message([bash("mix format --check-formatted")])]
      assert FileSurgery.detect(messages) == nil
    end

    test "prettier --write" do
      messages = [assistant_message([bash("prettier --write assets/js/app.js")])]
      assert FileSurgery.detect(messages) == nil
    end

    test "eslint --fix" do
      messages = [assistant_message([bash("eslint --fix assets/js/app.js")])]
      assert FileSurgery.detect(messages) == nil
    end

    test "git show with a TRACKED output target is still the sanctioned procedure" do
      messages = [assistant_message([bash("git show HEAD:lib/foo.ex > lib/foo.ex")])]
      assert FileSurgery.detect(messages) == nil
    end
  end

  describe "detect/1 — positives (family :slice_and_redirect)" do
    test "the real ORCAHUB3-61 incident command" do
      messages = [
        assistant_message([
          bash(
            "cat /home/zach/orca_hub/lib/orca_hub/pi_config_sync.ex | head -215 > /tmp/pi_config_part1.ex"
          )
        ])
      ]

      evidence = FileSurgery.detect(messages)

      assert evidence.path == "/home/zach/orca_hub/lib/orca_hub/pi_config_sync.ex"

      assert evidence.command ==
               "cat /home/zach/orca_hub/lib/orca_hub/pi_config_sync.ex | head -215 > /tmp/pi_config_part1.ex"

      assert evidence.kind == :slice_and_redirect
      assert evidence.paired_with_failed_edit == false
    end

    test "head -n with a target line count" do
      messages = [assistant_message([bash("head -n 100 lib/foo.ex > /tmp/a")])]

      assert FileSurgery.detect(messages).path == "lib/foo.ex"
    end

    test "sed -n with a quoted range" do
      messages = [assistant_message([bash("sed -n '1,50p' lib/foo.ex > /tmp/a")])]

      assert FileSurgery.detect(messages).path == "lib/foo.ex"
    end

    test "tail -n with a plus-offset, append redirect" do
      messages = [assistant_message([bash("tail -n +216 lib/foo.ex >> /tmp/b")])]

      assert FileSurgery.detect(messages).path == "lib/foo.ex"
    end

    test "awk with a script and a repo-relative path" do
      messages = [assistant_message([bash("awk '{print}' lib/foo.ex > /tmp/a")])]

      assert FileSurgery.detect(messages).path == "lib/foo.ex"
    end

    test "a repo-relative (not absolute) path fires just the same" do
      messages = [assistant_message([bash("cat lib/orca_hub/sessions/churn.ex > /tmp/x")])]

      assert FileSurgery.detect(messages).path == "lib/orca_hub/sessions/churn.ex"
    end

    test "returns the MOST RECENT match when several occur in the window" do
      messages = [
        assistant_message([bash("cat lib/a.ex > /tmp/a")]),
        assistant_message([bash("cat lib/b.ex > /tmp/b")])
      ]

      assert FileSurgery.detect(messages).path == "lib/b.ex"
    end

    test "paired_with_failed_edit: true when a failed Edit on the same path precedes it" do
      messages = [
        assistant_message([tool_use("t-edit", "Edit", %{"file_path" => "lib/foo.ex"})]),
        user_message([
          tool_result("t-edit",
            is_error: true,
            text: "Could not find the exact text in lib/foo.ex."
          )
        ]),
        assistant_message([bash("cat lib/foo.ex | head -50 > /tmp/x")])
      ]

      evidence = FileSurgery.detect(messages)

      assert evidence.path == "lib/foo.ex"
      assert evidence.kind == :slice_and_redirect
      assert evidence.paired_with_failed_edit == true
    end

    test "paired_with_failed_edit: false when the preceding Edit on the same path succeeded" do
      messages = [
        assistant_message([tool_use("t-edit", "Edit", %{"file_path" => "lib/foo.ex"})]),
        user_message([tool_result("t-edit", is_error: false, text: "ok")]),
        assistant_message([bash("cat lib/foo.ex | head -50 > /tmp/x")])
      ]

      evidence = FileSurgery.detect(messages)

      assert evidence.path == "lib/foo.ex"
      assert evidence.paired_with_failed_edit == false
    end

    test "paired_with_failed_edit: false when the failed edit was on a DIFFERENT path" do
      messages = [
        assistant_message([tool_use("t-edit", "Edit", %{"file_path" => "lib/other.ex"})]),
        user_message([tool_result("t-edit", is_error: true, text: "no match")]),
        assistant_message([bash("cat lib/foo.ex | head -50 > /tmp/x")])
      ]

      evidence = FileSurgery.detect(messages)

      assert evidence.path == "lib/foo.ex"
      assert evidence.paired_with_failed_edit == false
    end

    test "paired_with_failed_edit: false when the failed edit is outside the lookback window" do
      old_failed_edit = [
        tool_use("t-edit", "Edit", %{"file_path" => "lib/foo.ex"})
      ]

      filler =
        for n <- 1..11 do
          assistant_message([tool_use("t-filler-#{n}", "Read", %{"file_path" => "lib/other.ex"})])
        end

      messages =
        [
          assistant_message(old_failed_edit),
          user_message([tool_result("t-edit", is_error: true)])
        ] ++
          filler ++
          [assistant_message([bash("cat lib/foo.ex | head -50 > /tmp/x")])]

      evidence = FileSurgery.detect(messages)

      assert evidence.path == "lib/foo.ex"
      assert evidence.paired_with_failed_edit == false
    end
  end

  describe "detect/1 — exact path extraction (must not include flags)" do
    test "cat" do
      messages = [assistant_message([bash("cat lib/foo.ex > /tmp/a")])]
      assert FileSurgery.detect(messages).path == "lib/foo.ex"
    end

    test "head" do
      messages = [assistant_message([bash("head -n 100 lib/foo.ex > /tmp/a")])]
      assert FileSurgery.detect(messages).path == "lib/foo.ex"
    end

    test "tail" do
      messages = [assistant_message([bash("tail -n +216 lib/foo.ex >> /tmp/b")])]
      assert FileSurgery.detect(messages).path == "lib/foo.ex"
    end

    test "sed -n" do
      messages = [assistant_message([bash("sed -n '1,50p' lib/foo.ex > /tmp/a")])]
      assert FileSurgery.detect(messages).path == "lib/foo.ex"
    end

    test "awk" do
      messages = [assistant_message([bash("awk '{print}' lib/foo.ex > /tmp/a")])]
      assert FileSurgery.detect(messages).path == "lib/foo.ex"
    end
  end

  describe "detect/1 — must never fire" do
    test "git show <ref>:<path> — the sanctioned recovery procedure" do
      messages = [assistant_message([bash("git show HEAD:lib/foo.ex > /tmp/a")])]
      assert FileSurgery.detect(messages) == nil
    end

    test "git cat-file" do
      messages = [assistant_message([bash("git cat-file -p HEAD:lib/foo.ex > /tmp/a")])]
      assert FileSurgery.detect(messages) == nil
    end

    test "git diff" do
      messages = [assistant_message([bash("git diff HEAD~1 -- lib/foo.ex > /tmp/a")])]
      assert FileSurgery.detect(messages) == nil
    end

    test "git archive" do
      messages = [assistant_message([bash("git archive HEAD lib/foo.ex > /tmp/a.tar")])]
      assert FileSurgery.detect(messages) == nil
    end

    test "tailing a log file" do
      messages = [assistant_message([bash("tail -n 40 log/dev.log > /tmp/x")])]
      assert FileSurgery.detect(messages) == nil
    end

    test "writing a new /tmp scratch script with no tracked-file input" do
      messages = [assistant_message([bash("cat > /tmp/driver.js <<'EOF'\nconsole.log(1)\nEOF")])]
      assert FileSurgery.detect(messages) == nil
    end

    test "mix test with only a bare 2>&1 (no real output redirection)" do
      messages = [assistant_message([bash("mix test 2>&1")])]
      assert FileSurgery.detect(messages) == nil
    end

    test "a path under _build/" do
      messages = [assistant_message([bash("cat _build/dev/lib/orca_hub/priv/foo.ex > /tmp/a")])]
      assert FileSurgery.detect(messages) == nil
    end

    test "a path under deps/" do
      messages = [assistant_message([bash("cat deps/ecto/lib/ecto/query.ex > /tmp/a")])]
      assert FileSurgery.detect(messages) == nil
    end
  end

  describe "detect/1 — robustness" do
    test "returns nil when nothing matches" do
      messages = [assistant_message([bash("ls -la")])]
      assert FileSurgery.detect(messages) == nil
    end

    test "returns nil on an empty message list" do
      assert FileSurgery.detect([]) == nil
    end

    test "never raises on malformed input" do
      messages = [%{data: %{"type" => "assistant", "message" => %{"content" => "not a list"}}}]
      assert FileSurgery.detect(messages) == nil
    end

    test "detect/1 rejects non-list input rather than raising" do
      assert FileSurgery.detect(%{not: "a list"}) == nil
    end
  end

  describe "fetch/2" do
    defp fixture_session do
      dir =
        Path.join(System.tmp_dir!(), "file-surgery-test-#{System.unique_integer([:positive])}")

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
                %{
                  "type" => "tool_use",
                  "id" => "t1",
                  "name" => "Bash",
                  "input" => %{"command" => "cat lib/foo.ex > /tmp/a"}
                }
              ]
            }
          }
        })

      assert FileSurgery.fetch(session.id).path == "lib/foo.ex"
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
                %{
                  "type" => "tool_use",
                  "id" => "t1",
                  "name" => "Bash",
                  "input" => %{"command" => "cat lib/foo.ex > /tmp/a"}
                }
              ]
            }
          }
        })

      old = NaiveDateTime.utc_now() |> NaiveDateTime.add(-3600, :second)

      OrcaHub.Repo.update_all(
        from(m in Sessions.Message, where: m.id == ^message.id),
        set: [inserted_at: old]
      )

      assert FileSurgery.fetch(session.id, window_minutes: 30) == nil
    end
  end

  describe "fetch_many/2" do
    test "every requested session_id is a key of the result, even with no matches" do
      session_ids = [Ecto.UUID.generate(), Ecto.UUID.generate()]

      result = FileSurgery.fetch_many(session_ids)

      assert Map.keys(result) |> Enum.sort() == Enum.sort(session_ids)
      assert result[Enum.at(session_ids, 0)] == nil
      assert result[Enum.at(session_ids, 1)] == nil
    end

    test "batches real evidence per session in one query" do
      dir1 = Path.join(System.tmp_dir!(), "file-surgery-fm-#{System.unique_integer([:positive])}")
      dir2 = Path.join(System.tmp_dir!(), "file-surgery-fm-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir1)
      File.mkdir_p!(dir2)
      on_exit(fn -> File.rm_rf(dir1) end)
      on_exit(fn -> File.rm_rf(dir2) end)

      {:ok, session1} = Sessions.create_session(%{directory: dir1})
      {:ok, session2} = Sessions.create_session(%{directory: dir2})

      {:ok, _} =
        Sessions.create_message(%{
          session_id: session1.id,
          data: %{
            "type" => "assistant",
            "message" => %{
              "content" => [
                %{
                  "type" => "tool_use",
                  "id" => "t1",
                  "name" => "Bash",
                  "input" => %{"command" => "cat lib/foo.ex > /tmp/a"}
                }
              ]
            }
          }
        })

      result = FileSurgery.fetch_many([session1.id, session2.id])

      assert result[session1.id].path == "lib/foo.ex"
      assert result[session2.id] == nil
    end
  end
end
