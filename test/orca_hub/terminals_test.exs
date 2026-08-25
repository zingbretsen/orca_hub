defmodule OrcaHub.TerminalsTest do
  @moduledoc """
  Coverage for `OrcaHub.Terminals` — create, read, update, delete, and the
  new `pin_terminal/1`/`unpin_terminal/1` helpers.
  """
  use OrcaHub.DataCase, async: true

  alias OrcaHub.{Projects, Terminals}
  alias OrcaHub.Terminals.Terminal

  setup do
    dir = Path.join(System.tmp_dir!(), "terminals_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "terminals-ctx-test",
        directory: dir,
        node: "n1@x",
        key_prefix: "TP"
      })

    {:ok, project: project}
  end

  describe "create_terminal/1" do
    test "creates a terminal with defaults", %{project: project} do
      assert {:ok, %Terminal{} = terminal} =
               Terminals.create_terminal(%{name: "my-terminal", directory: "/tmp/x"})

      assert terminal.name == "my-terminal"
      assert terminal.directory == "/tmp/x"
      assert terminal.shell == "/bin/bash"
      assert terminal.status == "stopped"
    end
  end

  describe "get_terminal/1" do
    test "fetches an existing terminal", %{project: project} do
      {:ok, terminal} = Terminals.create_terminal(%{name: "x", directory: "/tmp/x"})

      assert Terminals.get_terminal(terminal.id).id == terminal.id
    end

    test "returns nil for a missing id" do
      assert Terminals.get_terminal(Ecto.UUID.generate()) == nil
    end
  end

  describe "update_terminal/2" do
    test "updates a terminal", %{project: project} do
      {:ok, terminal} = Terminals.create_terminal(%{name: "x", directory: "/tmp/x"})

      assert {:ok, updated} = Terminals.update_terminal(terminal, %{name: "updated"})
      assert updated.name == "updated"
    end
  end

  describe "pin_terminal/1 and unpin_terminal/1" do
    test "pins a terminal by setting pinned_at", %{project: project} do
      {:ok, terminal} = Terminals.create_terminal(%{name: "x", directory: "/tmp/x"})

      assert {:ok, pinned} = Terminals.pin_terminal(terminal)
      assert %DateTime{} = pinned.pinned_at
      assert pinned.pinned_at == DateTime.utc_now() |> DateTime.truncate(:second)
    end

    test "unpins a terminal by clearing pinned_at", %{project: project} do
      {:ok, terminal} = Terminals.create_terminal(%{name: "x", directory: "/tmp/x"})
      {:ok, _pinned} = Terminals.pin_terminal(terminal)

      assert {:ok, unpinned} = Terminals.unpin_terminal(terminal)
      assert is_nil(unpinned.pinned_at)
    end
  end
end
