defmodule OrcaHub.Projects.DirectoryMoveTest do
  use OrcaHub.DataCase, async: false

  alias OrcaHub.Jobs.Job
  alias OrcaHub.Projects
  alias OrcaHub.Projects.DirectoryMove
  alias OrcaHub.Projects.Project
  alias OrcaHub.Sessions.Session
  alias OrcaHub.Terminals.Terminal

  setup do
    # A real tmp tree, with an underscore in the name on purpose: `_` is a
    # LIKE wildcard, and unescaped it would let /tmp/orca_move_XXX match a
    # sibling like /tmp/orcaXmoveXXXX.
    root = Path.join(System.tmp_dir!(), "orca_move_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)

    {:ok, root: root}
  end

  defp mkdir(path) do
    File.mkdir_p!(path)
    path
  end

  defp project(directory, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Project{
          name: "p-#{System.unique_integer([:positive])}",
          directory: directory
        },
        attrs
      )
    )
  end

  defp session(directory, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Session{
          directory: directory,
          status: "idle",
          runner_node: to_string(node())
        },
        attrs
      )
    )
  end

  defp terminal(directory, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Terminal{
          name: "t-#{System.unique_integer([:positive])}",
          directory: directory,
          status: "stopped",
          runner_node: to_string(node())
        },
        attrs
      )
    )
  end

  defp job(directory, attrs \\ %{}) do
    Repo.insert!(
      struct(
        %Job{
          directory: directory,
          command: "sleep 1",
          status: "succeeded",
          runner_node: to_string(node())
        },
        attrs
      )
    )
  end

  defp reload(%Project{id: id}), do: Repo.get!(Project, id)
  defp reload(%Session{id: id}), do: Repo.get!(Session, id)
  defp reload(%Terminal{id: id}), do: Repo.get!(Terminal, id)
  defp reload(%Job{id: id}), do: Repo.get!(Job, id)

  describe "prefix boundary" do
    test "moving /a/foo does not touch /a/foobar", %{root: root} do
      foo = mkdir(Path.join(root, "foo"))
      foobar = mkdir(Path.join(root, "foobar"))
      dest = Path.join(root, "renamed")

      p = project(foo)
      sibling = project(foobar)
      inside = session(Path.join(foo, "sub"))
      outside = session(Path.join(foobar, "sub"))
      # The nastiest near-miss: identical prefix, different next character.
      lookalike = session(foo <> "bar/deep/nested")

      assert {:ok, result} = DirectoryMove.move(p, dest)

      assert result.from == foo
      assert result.to == dest
      assert reload(p).directory == dest
      assert reload(sibling).directory == foobar
      assert reload(inside).directory == Path.join(dest, "sub")
      assert reload(outside).directory == Path.join(foobar, "sub")
      assert reload(lookalike).directory == foo <> "bar/deep/nested"

      assert result.sessions == 1
      assert Enum.map(result.projects, & &1.id) == [p.id]

      assert File.dir?(dest)
      refute File.exists?(foo)
      assert File.dir?(foobar)
    end

    test "a LIKE wildcard in the source path is escaped, not matched", %{root: root} do
      # `_` is a single-character LIKE wildcard; `orca_x` must not match `orcaYx`.
      src = mkdir(Path.join(root, "orca_x"))
      mkdir(Path.join(root, "orcaYx"))
      dest = Path.join(root, "moved")

      p = project(src)
      decoy = session(Path.join(root, "orcaYx/work"))

      assert {:ok, _result} = DirectoryMove.move(p, dest)

      assert reload(p).directory == dest
      assert reload(decoy).directory == Path.join(root, "orcaYx/work")
    end
  end

  describe "rewrites" do
    test "nested projects, sessions, terminals and jobs all move with the tree", %{root: root} do
      src = mkdir(Path.join(root, "workspace"))
      mkdir(Path.join(src, ".worktrees/feature"))
      dest = Path.join(root, "workspace-renamed")

      p = project(src)
      nested = project(Path.join(src, ".worktrees/feature"))
      s1 = session(src)
      s2 = session(Path.join(src, ".worktrees/feature"))
      archived = session(Path.join(src, "old"), %{archived_at: DateTime.utc_now(:second)})
      t = terminal(Path.join(src, "sub"))
      j = job(src)

      assert {:ok, result} = DirectoryMove.move(p, dest)

      assert reload(p).directory == dest
      assert reload(nested).directory == Path.join(dest, ".worktrees/feature")
      assert reload(s1).directory == dest
      assert reload(s2).directory == Path.join(dest, ".worktrees/feature")
      assert reload(archived).directory == Path.join(dest, "old")
      assert reload(t).directory == Path.join(dest, "sub")
      assert reload(j).directory == dest

      # Archived rows are rewritten too, so they're in the count.
      assert result.sessions == 3
      assert result.terminals == 1
      assert result.jobs == 1
      assert result.side_effects == []

      ids = Enum.map(result.projects, & &1.id) |> Enum.sort()
      assert ids == Enum.sort([p.id, nested.id])

      nested_entry = Enum.find(result.projects, &(&1.id == nested.id))
      assert nested_entry.from == Path.join(src, ".worktrees/feature")
      assert nested_entry.to == Path.join(dest, ".worktrees/feature")

      # The nested project row is called out for the operator.
      assert Enum.any?(result.warnings, &String.contains?(&1, "other project row"))
    end

    test "jobs' log/sentinel paths are left alone (they live outside the tree)", %{root: root} do
      src = mkdir(Path.join(root, "app"))
      dest = Path.join(root, "app2")
      p = project(src)

      log = Path.expand("~/.orca_hub/jobs/abc.log")
      j = job(src, %{log_path: log, sentinel_path: Path.expand("~/.orca_hub/jobs/abc.exit")})

      assert {:ok, _} = DirectoryMove.move(p, dest)

      moved = reload(j)
      assert moved.directory == dest
      assert moved.log_path == log
    end

    test "moving to a different parent directory relocates the tree", %{root: root} do
      src = mkdir(Path.join(root, "here/app"))
      File.write!(Path.join(src, "file.txt"), "hi")
      mkdir(Path.join(root, "elsewhere"))
      dest = Path.join(root, "elsewhere/app")

      p = project(src)

      assert {:ok, result} = DirectoryMove.move(p, dest)
      assert result.node == node()
      assert File.read!(Path.join(dest, "file.txt")) == "hi"
      assert reload(p).directory == dest
    end
  end

  describe "validation" do
    test "rejects a destination inside the source", %{root: root} do
      src = mkdir(Path.join(root, "app"))
      p = project(src)

      assert {:error, {:nested_destination, msg}} =
               DirectoryMove.move(p, Path.join(src, "inner"))

      assert msg =~ "inside"
      assert reload(p).directory == src
    end

    test "rejects an existing destination", %{root: root} do
      src = mkdir(Path.join(root, "app"))
      dest = mkdir(Path.join(root, "taken"))
      p = project(src)

      assert {:error, {:destination_exists, msg}} = DirectoryMove.move(p, dest)
      assert msg =~ dest
      assert File.dir?(src)
    end

    test "rejects a destination whose parent does not exist", %{root: root} do
      src = mkdir(Path.join(root, "app"))
      p = project(src)

      assert {:error, {:destination_parent_missing, msg}} =
               DirectoryMove.move(p, Path.join(root, "nope/app"))

      assert msg =~ Path.join(root, "nope")
      assert File.dir?(src)
    end

    test "rejects the same directory, relative paths, and blanks", %{root: root} do
      src = mkdir(Path.join(root, "app"))
      p = project(src)

      assert {:error, {:same_directory, _}} = DirectoryMove.move(p, src)
      assert {:error, {:same_directory, _}} = DirectoryMove.move(p, src <> "/")
      assert {:error, {:invalid_path, _}} = DirectoryMove.move(p, "relative/path")
      assert {:error, {:invalid_path, _}} = DirectoryMove.move(p, "   ")
      assert {:error, {:invalid_path, _}} = DirectoryMove.move(p, "~/somewhere")
    end

    test "rejects a source that is missing or not a directory", %{root: root} do
      missing = project(Path.join(root, "gone"))

      assert {:error, {:source_missing, _}} = DirectoryMove.move(missing, Path.join(root, "x"))

      file = Path.join(root, "file")
      File.write!(file, "")
      as_file = project(file)

      assert {:error, {:not_a_directory, _}} = DirectoryMove.move(as_file, Path.join(root, "y"))
    end
  end

  describe "blockers" do
    test "live sessions, running terminals and running jobs block the move", %{root: root} do
      src = mkdir(Path.join(root, "app"))
      dest = Path.join(root, "app2")
      p = project(src)

      running = session(src, %{status: "running", title: "busy worker"})
      waiting = session(Path.join(src, "sub"), %{status: "waiting"})
      compacting = session(src, %{status: "compacting"})
      session(src, %{status: "running", archived_at: DateTime.utc_now(:second)})
      t = terminal(src, %{status: "running"})
      j = job(src, %{status: "verifying"})

      assert {:ok, plan} = DirectoryMove.plan(p, dest)

      assert length(plan.blockers) == 5
      assert Enum.any?(plan.blockers, &String.contains?(&1, running.id))
      assert Enum.any?(plan.blockers, &String.contains?(&1, "busy worker"))
      assert Enum.any?(plan.blockers, &String.contains?(&1, waiting.id))
      assert Enum.any?(plan.blockers, &String.contains?(&1, compacting.id))
      assert Enum.any?(plan.blockers, &String.contains?(&1, t.id))
      assert Enum.any?(plan.blockers, &String.contains?(&1, j.id))

      assert {:error, {:blocked, msg}} = DirectoryMove.move(p, dest)
      assert msg =~ "busy worker"
      assert File.dir?(src)
      refute File.exists?(dest)
      assert reload(p).directory == src
    end

    test "force: true moves anyway and copies blockers into warnings", %{root: root} do
      src = mkdir(Path.join(root, "app"))
      dest = Path.join(root, "app2")
      p = project(src)
      s = session(src, %{status: "running"})

      assert {:ok, result} = DirectoryMove.move(p, dest, force: true)

      assert result.blockers != []
      assert Enum.any?(result.warnings, &String.contains?(&1, "forced past blocker"))
      assert Enum.any?(result.warnings, &String.contains?(&1, s.id))
      assert reload(p).directory == dest
      assert reload(s).directory == dest
      assert File.dir?(dest)
    end
  end

  describe "rollback" do
    test "a failing DB rewrite moves the directory back", %{root: root} do
      src = mkdir(Path.join(root, "app"))
      File.write!(Path.join(src, "marker"), "x")
      dest = Path.join(root, "app2")
      p = project(src)
      s = session(src)

      assert {:error, {:rewrite_failed, msg}} =
               DirectoryMove.move(p, dest, rewrite_fun: fn _from, _to -> {:error, "boom"} end)

      assert msg =~ "boom"
      assert msg =~ "moved back"
      refute msg =~ "ROLLBACK FAILED"

      # Directory back where it started, rows untouched.
      assert File.read!(Path.join(src, "marker")) == "x"
      refute File.exists?(dest)
      assert reload(p).directory == src
      assert reload(s).directory == src
    end

    test "a raising DB rewrite is caught and also rolled back", %{root: root} do
      src = mkdir(Path.join(root, "app"))
      dest = Path.join(root, "app2")
      p = project(src)

      assert {:error, {:rewrite_failed, msg}} =
               DirectoryMove.move(p, dest, rewrite_fun: fn _, _ -> raise "kaboom" end)

      assert msg =~ "kaboom"
      assert File.dir?(src)
      refute File.exists?(dest)
      assert reload(p).directory == src
    end
  end

  describe "plan/2" do
    test "mutates nothing on disk or in the database", %{root: root} do
      src = mkdir(Path.join(root, "app"))
      mkdir(Path.join(src, "nested"))
      dest = Path.join(root, "app2")

      p = project(src)
      nested = project(Path.join(src, "nested"))
      s = session(Path.join(src, "sub"))
      t = terminal(src)
      j = job(src)

      assert {:ok, plan} = DirectoryMove.plan(p, dest)

      assert plan.from == src
      assert plan.to == dest
      assert plan.node == node()
      assert plan.sessions == 1
      assert plan.terminals == 1
      assert plan.jobs == 1
      assert plan.blockers == []
      assert plan.side_effects == []
      assert Enum.sort(Enum.map(plan.projects, & &1.id)) == Enum.sort([p.id, nested.id])

      assert Map.keys(plan) |> Enum.sort() ==
               Enum.sort([
                 :from,
                 :to,
                 :node,
                 :projects,
                 :sessions,
                 :terminals,
                 :jobs,
                 :blockers,
                 :warnings,
                 :side_effects
               ])

      # Nothing moved, nothing rewritten.
      assert File.dir?(src)
      refute File.exists?(dest)
      assert reload(p).directory == src
      assert reload(nested).directory == Path.join(src, "nested")
      assert reload(s).directory == Path.join(src, "sub")
      assert reload(t).directory == src
      assert reload(j).directory == src
    end

    test "normalizes the destination and reports the same keys as move/3", %{root: root} do
      src = mkdir(Path.join(root, "app"))
      p = project(src)
      messy = "  " <> Path.join(root, "./out/../app2") <> "/  "

      assert {:ok, plan} = DirectoryMove.plan(p, messy)
      assert plan.to == Path.join(root, "app2")

      assert {:ok, result} = DirectoryMove.move(p, messy)
      assert Map.keys(result) |> Enum.sort() == Map.keys(plan) |> Enum.sort()
      assert result.to == Path.join(root, "app2")
      assert File.dir?(Path.join(root, "app2"))
    end
  end

  describe "Projects wrappers" do
    test "plan_directory_move/2 and move_directory/3 delegate", %{root: root} do
      src = mkdir(Path.join(root, "app"))
      dest = Path.join(root, "app2")
      p = project(src)

      assert {:ok, plan} = Projects.plan_directory_move(p, dest)
      assert plan.to == dest

      assert {:ok, result} = Projects.move_directory(p, dest)
      assert result.to == dest
      assert reload(p).directory == dest
    end

    test "move_directory/3 passes force through", %{root: root} do
      src = mkdir(Path.join(root, "app"))
      dest = Path.join(root, "app2")
      p = project(src)
      session(src, %{status: "running"})

      assert {:error, {:blocked, _}} = Projects.move_directory(p, dest)
      assert {:ok, _} = Projects.move_directory(p, dest, force: true)
    end
  end

  describe "broadcasts" do
    test "subscribers on sessions/terminals/projects are notified", %{root: root} do
      src = mkdir(Path.join(root, "app"))
      dest = Path.join(root, "app2")
      p = project(src)
      s = session(src)

      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "projects")
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "terminals")
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{s.id}")

      assert {:ok, _} = DirectoryMove.move(p, dest)

      project_id = p.id
      session_id = s.id

      assert_receive {^project_id, {:project_directory_moved, %{from: ^src, to: ^dest}}}
      assert_receive {^session_id, {:directory_moved, %{to: ^dest}}}
      assert_receive {:directory_moved, %{to: ^dest}}
    end
  end
end
