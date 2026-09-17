defmodule OrcaHub.Projects.MoveSideEffectsTest do
  use ExUnit.Case, async: true

  alias OrcaHub.AgentMemory
  alias OrcaHub.Projects.MoveSideEffects

  setup do
    home = Path.join(System.tmp_dir!(), "orca_side_effects_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join([home, ".claude", "projects"]))
    on_exit(fn -> File.rm_rf(home) end)

    {:ok, home: home}
  end

  # The real slug directory for `directory` under the injected home, i.e. the
  # parent of what `AgentMemory.claude_memory_dir/2` points at.
  defp slug_dir(home, directory) do
    Path.join([home, ".claude", "projects", AgentMemory.slugify(directory)])
  end

  defp seed_history!(home, directory) do
    dir = slug_dir(home, directory)
    File.mkdir_p!(Path.join(dir, "memory"))
    File.write!(Path.join(dir, "session.jsonl"), ~s({"cwd":"#{directory}"}\n))
    File.write!(Path.join([dir, "memory", "MEMORY.md"]), "- a memory\n")
    dir
  end

  # A memory-service double. `:list` is a list of canned responses, consumed
  # one per call (the last one repeats); `:updates` collects what was PATCHed.
  defmodule FakeMemoryClient do
    def start(opts) do
      {:ok, pid} = Agent.start_link(fn -> %{list: opts[:list] || [], updates: []} end)
      Process.put(__MODULE__, pid)
      pid
    end

    def list(params) do
      Agent.get_and_update(pid(), fn state ->
        {response, rest} =
          case state.list do
            [only] -> {only, [only]}
            [next | rest] -> {next, rest}
            [] -> {{:ok, %{"memories" => []}}, []}
          end

        response = if is_function(response, 1), do: response.(params), else: response
        {response, %{state | list: rest}}
      end)
    end

    def update(id, attrs) do
      Agent.get_and_update(pid(), fn state ->
        {{:ok, %{"memory" => %{"id" => id}}}, %{state | updates: state.updates ++ [{id, attrs}]}}
      end)
    end

    def updates, do: Agent.get(pid(), & &1.updates)

    defp pid, do: Process.get(__MODULE__)
  end

  defmodule RaisingMemoryClient do
    def list(_params), do: raise("memory service exploded")
    def update(_id, _attrs), do: raise("memory service exploded")
  end

  defmodule FailingUpdateClient do
    def list(_params),
      do: {:ok, %{"memories" => [%{"id" => "m1", "project" => %{"slug" => "old"}}]}}

    def update(_id, _attrs), do: {:error, {:http_error, 500, "boom"}}
  end

  defp memory(id, project) do
    %{"id" => id, "text" => "t#{id}", "project" => project}
  end

  describe "Claude history/memory directory" do
    test "renames the old slug directory onto the new one", %{home: home} do
      from = "/home/zach/old_project"
      to = "/home/zach/nested/new-project"

      src = seed_history!(home, from)
      dst = slug_dir(home, to)

      {:ok, notes} = MoveSideEffects.apply(node(), from, to, home_dir: home)

      refute File.exists?(src)
      assert File.exists?(Path.join(dst, "session.jsonl"))
      assert File.read!(Path.join([dst, "memory", "MEMORY.md"])) == "- a memory\n"

      # And the directory it landed in is exactly the one AgentMemory will
      # look in for the moved project.
      assert AgentMemory.claude_memory_dir(to, home_dir: home) == Path.join(dst, "memory")

      assert Enum.any?(notes, &String.contains?(&1, "Renamed Claude's history/memory directory"))
      assert Enum.any?(notes, &String.contains?(&1, dst))
      refute Enum.any?(notes, &String.contains?(&1, "WARNING"))
    end

    test "skips and warns when the destination slug directory already exists", %{home: home} do
      from = "/home/zach/old_project"
      to = "/home/zach/new_project"

      src = seed_history!(home, from)
      dst = seed_history!(home, to)
      File.write!(Path.join(dst, "session.jsonl"), "PRE-EXISTING\n")

      {:ok, notes} = MoveSideEffects.apply(node(), from, to, home_dir: home)

      # Nothing clobbered, nothing merged, both histories intact.
      assert File.exists?(Path.join(src, "session.jsonl"))
      assert File.read!(Path.join(dst, "session.jsonl")) == "PRE-EXISTING\n"

      warning = Enum.find(notes, &String.contains?(&1, "WARNING"))
      assert warning =~ "was NOT migrated"
      assert warning =~ dst
      assert warning =~ src
    end

    test "a missing source slug directory is a clean no-op, not an error", %{home: home} do
      from = "/home/zach/never_used_by_claude"
      to = "/home/zach/moved_there"

      assert {:ok, notes} = MoveSideEffects.apply(node(), from, to, home_dir: home)

      assert notes == []
      refute File.exists?(slug_dir(home, to))
    end

    test "two paths sharing one slug are reported as nothing-to-do", %{home: home} do
      # The slug transform is lossy: `_` and `-` both become `-`.
      from = "/home/zach/orca_hub"
      to = "/home/zach/orca-hub"
      assert AgentMemory.slugify(from) == AgentMemory.slugify(to)

      src = seed_history!(home, from)

      {:ok, notes} = MoveSideEffects.apply(node(), from, to, home_dir: home)

      assert File.exists?(Path.join(src, "session.jsonl"))
      note = Enum.find(notes, &String.contains?(&1, "needed no change"))
      assert note =~ "share the slug directory"
      refute Enum.any?(notes, &String.contains?(&1, "WARNING"))
    end

    test "an unreachable node warns and is never re-routed to another node", %{home: home} do
      from = "/home/zach/old_project"
      to = "/home/zach/new_project"
      seed_history!(home, from)

      {:ok, notes} =
        MoveSideEffects.apply(:"nonexistent@127.0.0.1", from, to, home_dir: home)

      warning = Enum.find(notes, &String.contains?(&1, "WARNING"))
      assert warning =~ "could not migrate Claude's history/memory directory"
      assert warning =~ "NOT re-routed to another node"

      # The work was NOT quietly done on this node instead.
      assert File.exists?(slug_dir(home, from))
      refute File.exists?(slug_dir(home, to))
    end

    test "a nil node (no node assigned) warns rather than falling back locally", %{home: home} do
      from = "/home/zach/old_project"
      to = "/home/zach/new_project"
      seed_history!(home, from)

      {:ok, notes} = MoveSideEffects.apply(nil, from, to, home_dir: home)

      assert Enum.find(notes, &String.contains?(&1, "no node assigned"))
      assert File.exists?(slug_dir(home, from))
    end
  end

  describe "memory-service project slug" do
    test "repoints every memory, draining page 1 until empty", %{home: home} do
      from = "/home/zach/old_project"
      to = "/home/zach/new_project"
      old_slug = AgentMemory.slugify(from)
      new_slug = AgentMemory.slugify(to)

      FakeMemoryClient.start(
        list: [
          {:ok,
           %{
             "memories" => [
               memory("m1", %{"id" => "p1", "name" => "Explicit Name", "slug" => old_slug}),
               memory("m2", %{"id" => "p1", "name" => "old_project", "slug" => old_slug})
             ]
           }},
          {:ok, %{"memories" => [memory("m3", %{"id" => "p1", "slug" => old_slug})]}},
          {:ok, %{"memories" => []}}
        ]
      )

      {:ok, notes} =
        MoveSideEffects.apply(node(), from, to,
          home_dir: home,
          memory_client: FakeMemoryClient
        )

      updates = FakeMemoryClient.updates()
      assert Enum.map(updates, &elem(&1, 0)) == ["m1", "m2", "m3"]

      # Every PATCH carries the FULL project object, since the service
      # shallow-merges it — `id` must survive.
      assert {"m1", %{"project" => p1}} = Enum.at(updates, 0)
      assert p1 == %{"id" => "p1", "name" => "Explicit Name", "slug" => new_slug}

      # A name that was the old directory's basename follows the move;
      # an explicit project name (above) does not.
      assert {"m2", %{"project" => p2}} = Enum.at(updates, 1)
      assert p2 == %{"id" => "p1", "name" => "new_project", "slug" => new_slug}

      assert {"m3", %{"project" => p3}} = Enum.at(updates, 2)
      assert p3 == %{"id" => "p1", "name" => "new_project", "slug" => new_slug}

      assert Enum.any?(notes, &(&1 =~ "Repointed 3 memory-service memories"))
      refute Enum.any?(notes, &String.contains?(&1, "WARNING"))
    end

    test "no memories under the old slug produces no note", %{home: home} do
      FakeMemoryClient.start(list: [{:ok, %{"memories" => []}}])

      {:ok, notes} =
        MoveSideEffects.apply(node(), "/a/b", "/a/c",
          home_dir: home,
          memory_client: FakeMemoryClient
        )

      assert notes == []
      assert FakeMemoryClient.updates() == []
    end

    test "a disabled memory service is silent, not a warning", %{home: home} do
      # No :memory_client override — config/test.exs leaves
      # memory_service_url/token nil, so the real client reports :disabled.
      {:ok, notes} = MoveSideEffects.apply(node(), "/a/b", "/a/c", home_dir: home)

      assert notes == []
    end

    test "a listing error warns and names the old slug", %{home: home} do
      from = "/home/zach/old_project"
      FakeMemoryClient.start(list: [{:error, {:http_error, 503, "down"}}])

      {:ok, notes} =
        MoveSideEffects.apply(node(), from, "/home/zach/new_project",
          home_dir: home,
          memory_client: FakeMemoryClient
        )

      warning = Enum.find(notes, &String.contains?(&1, "WARNING"))
      assert warning =~ "memory-service migration"
      assert warning =~ "listing them failed"
      assert warning =~ "still filed under the OLD project slug"
    end

    test "failing updates stop the drain instead of looping forever", %{home: home} do
      {:ok, notes} =
        MoveSideEffects.apply(node(), "/home/zach/old_project", "/home/zach/new_project",
          home_dir: home,
          memory_client: FailingUpdateClient
        )

      warning = Enum.find(notes, &String.contains?(&1, "WARNING"))
      assert warning =~ "1 could not be updated"
      assert warning =~ "m1"
    end

    test "a move whose slug does not change skips the memory migration entirely", %{home: home} do
      FakeMemoryClient.start(list: [{:error, :should_never_be_called}])

      {:ok, notes} =
        MoveSideEffects.apply(node(), "/home/zach/orca_hub", "/home/zach/orca-hub",
          home_dir: home,
          memory_client: FakeMemoryClient
        )

      refute Enum.any?(notes, &String.contains?(&1, "memory-service"))
      assert FakeMemoryClient.updates() == []
    end
  end

  describe "independence and the never-raise contract" do
    test "a raising memory client does not stop the Claude rename", %{home: home} do
      from = "/home/zach/old_project"
      to = "/home/zach/new_project"
      src = seed_history!(home, from)

      {:ok, notes} =
        MoveSideEffects.apply(node(), from, to,
          home_dir: home,
          memory_client: RaisingMemoryClient
        )

      # The Claude half still ran to completion...
      refute File.exists?(src)
      assert File.exists?(Path.join(slug_dir(home, to), "session.jsonl"))
      assert Enum.any?(notes, &(&1 =~ "Renamed Claude's history/memory directory"))

      # ...and the memory half's crash is reported rather than raised.
      assert Enum.any?(
               notes,
               &(&1 =~ "memory-service project slug" and &1 =~ "memory service exploded")
             )
    end

    test "a Claude-side failure does not stop the memory migration", %{home: home} do
      from = "/home/zach/old_project"
      to = "/home/zach/new_project"
      old_slug = AgentMemory.slugify(from)

      # Force the Claude half to warn (destination already occupied) while the
      # memory half succeeds.
      seed_history!(home, from)
      seed_history!(home, to)

      FakeMemoryClient.start(
        list: [
          {:ok, %{"memories" => [memory("m1", %{"id" => "p1", "slug" => old_slug})]}},
          {:ok, %{"memories" => []}}
        ]
      )

      {:ok, notes} =
        MoveSideEffects.apply(node(), from, to,
          home_dir: home,
          memory_client: FakeMemoryClient
        )

      assert Enum.any?(notes, &(&1 =~ "was NOT migrated"))
      assert Enum.any?(notes, &(&1 =~ "Repointed 1 memory-service memory"))
      assert Enum.map(FakeMemoryClient.updates(), &elem(&1, 0)) == ["m1"]
    end

    test "returns {:ok, notes} even when the memory client returns garbage", %{home: home} do
      defmodule GarbageClient do
        def list(_params), do: :who_knows
        def update(_id, _attrs), do: :nope
      end

      assert {:ok, notes} =
               MoveSideEffects.apply(node(), "/a/b", "/a/c",
                 home_dir: home,
                 memory_client: GarbageClient
               )

      assert Enum.any?(notes, &(&1 =~ "WARNING" and &1 =~ "unexpected response"))
    end

    test "never raises when the memory client module does not exist", %{home: home} do
      assert {:ok, notes} =
               MoveSideEffects.apply(node(), "/a/b", "/a/c",
                 home_dir: home,
                 memory_client: NotAModuleAtAll
               )

      assert Enum.any?(notes, &String.contains?(&1, "WARNING"))
    end

    test "the DirectoryMove contract holds: always {:ok, list_of_strings}", %{home: home} do
      seed_history!(home, "/home/zach/old_project")

      assert {:ok, notes} =
               MoveSideEffects.apply(node(), "/home/zach/old_project", "/home/zach/new_project",
                 home_dir: home
               )

      assert is_list(notes)
      assert Enum.all?(notes, &is_binary/1)
    end
  end

  describe "Claude's real slug convention" do
    test "slugify/1 reproduces the conventions observed in a real ~/.claude/projects" do
      # Cases taken from directories that actually exist on the dev host,
      # cross-checked against the `cwd` recorded inside their transcripts.
      assert AgentMemory.slugify("/home/zach/orca_hub") == "-home-zach-orca-hub"

      assert AgentMemory.slugify("/home/zach/experiments/Ideation") ==
               "-home-zach-experiments-Ideation"

      assert AgentMemory.slugify("/tmp") == "-tmp"
      assert AgentMemory.slugify("/home/zach/homelab/k3s") == "-home-zach-homelab-k3s"
    end
  end
end
