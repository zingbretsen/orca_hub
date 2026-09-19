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

  describe "detect/1 — defect A.6(1): the reported path must be the WRITE TARGET" do
    test "a heredoc script that READS a tracked file and writes /tmp does not fire" do
      # The corpus defect verbatim: `match_family_c/1` used to split the whole
      # command and return the first tracked-looking token, so this was
      # delivered as "worker rebuilding lib/foo.ex".
      messages = [
        assistant_message([
          bash("""
          python3 - <<'PY'
          src = open('lib/foo.ex').read()
          open("/tmp/out.txt", "w").write(src)
          PY\
          """)
        ])
      ]

      assert FileSurgery.detect(messages) == nil
    end

    test "a genuine File.write! on a tracked path still fires and names it" do
      messages = [
        assistant_message([
          bash(
            "mix run --no-start -e 'old = File.read!(\"lib/bar.ex\")\nFile.write!(\"lib/foo.ex\", old)'"
          )
        ])
      ]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "lib/foo.ex"
      assert evidence.kind == :programmatic_write
    end

    test "a write target bound to a literal EARLIER in the same command resolves" do
      # The overwhelmingly common corpus shape: `p='x.py'` … `open(p,'w')`.
      messages = [
        assistant_message([
          bash("""
          python3 - <<'PY'
          p='tests/test_execution.py'
          s=open(p).read()
          open(p,'w').write(s.replace(old, new))
          PY\
          """)
        ])
      ]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "tests/test_execution.py"
      assert evidence.kind == :programmatic_write
    end

    test "a rebound write variable resolves to the binding in force AT that write" do
      # Straight-line patch scripts rebind the same name per file; BOTH files
      # are written, and the reported path must be one of them.
      messages = [
        assistant_message([
          bash("""
          python3 - <<'PY'
          p='lib/first.ex'
          open(p,'w').write(a)
          p='lib/second.ex'
          open(p,'w').write(b)
          PY\
          """)
        ])
      ]

      assert FileSurgery.detect(messages).path == "lib/first.ex"
    end

    test "pathlib: p = pathlib.Path(\"build_clips.py\") … p.write_text(s) fires" do
      # Hand-labelled true positive #30 of churn_alert_precision.md — it must
      # survive the defect-1 fix.
      messages = [
        assistant_message([
          bash("""
          cd tmp/voice2c && python3 - <<'PY'
          import pathlib
          p = pathlib.Path("build_clips.py")
          s = p.read_text()
          p.write_text(s.replace(old, new))
          PY\
          """)
        ])
      ]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "build_clips.py"
      assert evidence.kind == :programmatic_write
    end

    test "an INDETERMINATE write target returns nil rather than guessing" do
      # `dst` is computed, so nothing in the command says which file is
      # written — and `lib/foo.ex`, which it merely reads, must not be named.
      messages = [
        assistant_message([
          bash("""
          python3 - <<'PY'
          text = open('lib/foo.ex').read()
          dst = os.path.join(outdir, name)
          open(dst, "w").write(text)
          PY\
          """)
        ])
      ]

      assert FileSurgery.detect(messages) == nil
    end
  end

  describe "detect/1 — defect A.6(2): `>` inside a quoted string is not a redirect" do
    test "the sed 's/PASSWORD=.*/PASSWORD=<redacted>/' pure-read command does not fire" do
      # Sample #27, verbatim: one of only two `slice_and_redirect` alerts ever
      # delivered, and a pure READ. Its `>` is the literal `<redacted>`.
      messages = [
        assistant_message([
          bash(
            "cat config/test.exs | head -40 && echo \"=== env ===\" && " <>
              "env | grep -i -E \"database|postgres\" | sed 's/PASSWORD=.*/PASSWORD=<redacted>/'"
          )
        ])
      ]

      assert FileSurgery.detect(messages) == nil
    end

    test "an ASCII arrow inside an echo is not a redirect (the §E deploy-runner shape)" do
      messages = [
        assistant_message([
          bash(
            "cd /home/zach/orca-hub-deploy-logs && cp run-a.sh run-b.sh && " <>
              "echo \"=== diff run-a.sh -> run-b.sh ===\" && diff run-a.sh run-b.sh; echo \"(rc=$?)\""
          )
        ])
      ]

      assert FileSurgery.detect(messages) == nil
    end

    test "a real `cat x > lib/foo.ex` still fires after quote-stripping" do
      messages = [assistant_message([bash("cat /tmp/x > lib/foo.ex")])]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "lib/foo.ex"
      assert evidence.kind == :write_to_tracked
    end

    test "a quoted `>` no longer SHADOWS the command's real redirect target" do
      # The quoted arrow used to be found first, so the extracted target was
      # garbage and the match fell through to a later family naming a file the
      # command only read.
      messages = [
        assistant_message([
          bash("echo \"patching a => b\" && cat /tmp/new.js > assets/js/app.js")
        ])
      ]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "assets/js/app.js"
      assert evidence.kind == :write_to_tracked
    end

    test "a `>` in a heredoc BODY is data, not a redirect" do
      messages = [
        assistant_message([
          bash("""
          python3 - <<'PY'
          print("wrote lib/foo.ex > /tmp/nope")
          PY\
          """)
        ])
      ]

      assert FileSurgery.detect(messages) == nil
    end

    test "quote-blanking does not shift the redirect target that follows it" do
      messages = [
        assistant_message([bash("sed -n '1,50p' lib/foo.ex > /tmp/slice.txt")])
      ]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "lib/foo.ex"
      assert evidence.kind == :slice_and_redirect
    end
  end

  describe "detect/1 — verified_in_command (the measured D2b signal)" do
    test "true when the same command READS the written path back" do
      messages = [
        assistant_message([bash("cat /tmp/new.ex > lib/foo.ex && head -20 lib/foo.ex")])
      ]

      assert FileSurgery.detect(messages).verified_in_command == true
    end

    test "true when the same command EXECUTES what it wrote" do
      messages = [
        assistant_message([
          bash("cat /tmp/x > tmp/probe.exs && mix run --no-start tmp/probe.exs")
        ])
      ]

      assert FileSurgery.detect(messages).verified_in_command == true
    end

    test "false for a bare write with no verification" do
      messages = [assistant_message([bash("cat /tmp/new.ex > lib/foo.ex")])]

      assert FileSurgery.detect(messages).verified_in_command == false
    end

    test "the §C.4 live specimen (write heredoc, then `mix run` it) is verified" do
      # This alert fired on the session that produced churn_alert_precision.md.
      # Read-back alone (D2a) misses it; catching it is the measured argument
      # for the wider read-back-OR-execute form.
      messages = [
        assistant_message([
          bash("""
          cat > /home/zach/orca-hub-churn-analysis/probe1.exs <<'EOF'
          IO.puts("hi")
          EOF
          export $(grep -E '^DB_' .env | xargs) && mix run --no-start --no-compile \
          /home/zach/orca-hub-churn-analysis/probe1.exs 2>&1 | head -80\
          """)
        ])
      ]

      evidence = FileSurgery.detect(messages)
      assert evidence.path == "/home/zach/orca-hub-churn-analysis/probe1.exs"
      assert evidence.verified_in_command == true
    end
  end

  describe "detect/1 — same_path_matches (INFORMATIONAL ONLY, never a gate)" do
    test "counts every match on the reported path across the window" do
      messages = [
        assistant_message([bash("cat /tmp/a > lib/foo.ex")]),
        assistant_message([bash("cat /tmp/b > lib/other.ex")]),
        assistant_message([bash("sed -i 's/a/b/' lib/foo.ex")]),
        assistant_message([bash("cat /tmp/c > lib/foo.ex")])
      ]

      evidence = FileSurgery.detect(messages)

      assert evidence.path == "lib/foo.ex"
      assert evidence.same_path_matches == 3
    end

    test "is 1 for a single match, and never 0" do
      messages = [assistant_message([bash("cat /tmp/a > lib/foo.ex")])]

      assert FileSurgery.detect(messages).same_path_matches == 1
    end

    test "does not count matches on OTHER paths" do
      messages = [
        assistant_message([bash("cat /tmp/a > lib/one.ex")]),
        assistant_message([bash("cat /tmp/b > lib/two.ex")])
      ]

      evidence = FileSurgery.detect(messages)

      assert evidence.path == "lib/two.ex"
      assert evidence.same_path_matches == 1
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

    test "never raises on an invalid session_id, returns nil" do
      assert FileSurgery.fetch("not-a-uuid") == nil
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

    test "never raises when some ids are invalid; every id is still a key" do
      session_ids = ["not-a-uuid", Ecto.UUID.generate()]

      result = FileSurgery.fetch_many(session_ids)

      assert Map.keys(result) |> Enum.sort() == Enum.sort(session_ids)
      assert result["not-a-uuid"] == nil
    end

    test "one bad id does not suppress a good session's evidence" do
      dir =
        Path.join(System.tmp_dir!(), "file-surgery-badid-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      {:ok, session} = Sessions.create_session(%{directory: dir})

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

      result = FileSurgery.fetch_many(["not-a-uuid", session.id])

      assert result["not-a-uuid"] == nil
      assert result[session.id].path == "lib/foo.ex"
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
