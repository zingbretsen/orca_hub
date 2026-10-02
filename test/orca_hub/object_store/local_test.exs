defmodule OrcaHub.ObjectStore.LocalTest do
  use ExUnit.Case, async: true

  alias OrcaHub.ObjectStore.Local

  setup do
    dir =
      Path.join(System.tmp_dir!(), "object_store_local_#{System.unique_integer([:positive])}")

    Application.put_env(:orca_hub, :file_store_dir, dir)

    on_exit(fn ->
      Application.delete_env(:orca_hub, :file_store_dir)
      File.rm_rf(dir)
    end)

    {:ok, dir: dir}
  end

  test "put/1 then get/1 round-trips the exact bytes" do
    assert :ok = Local.put("proj1/file1/hello.txt", "hello world", "text/plain")
    assert {:ok, "hello world"} = Local.get("proj1/file1/hello.txt")
  end

  test "put/1 creates intermediate directories as needed", %{dir: dir} do
    assert :ok = Local.put("a/b/c/deep.bin", <<1, 2, 3>>, nil)
    assert File.exists?(Path.join(dir, "a/b/c/deep.bin"))
  end

  test "get/1 on a missing key returns an error" do
    assert {:error, :enoent} = Local.get("nope/nope/nope.txt")
  end

  test "delete/1 removes the object" do
    :ok = Local.put("proj1/file2/bye.txt", "bye", "text/plain")
    assert :ok = Local.delete("proj1/file2/bye.txt")
    assert {:error, :enoent} = Local.get("proj1/file2/bye.txt")
  end

  test "delete/1 on a missing key is still :ok (idempotent)" do
    assert :ok = Local.delete("never/existed/at/all.txt")
  end

  describe "get_range/3" do
    setup do
      :ok = Local.put("proj1/file3/range.bin", "0123456789", "application/octet-stream")
      :ok
    end

    test "reads exactly the requested window" do
      assert {:ok, "234"} = Local.get_range("proj1/file3/range.bin", 2, 3)
      assert {:ok, "0"} = Local.get_range("proj1/file3/range.bin", 0, 1)
    end

    test "a window running past the end is a short read" do
      assert {:ok, "89"} = Local.get_range("proj1/file3/range.bin", 8, 100)
    end

    test "an offset at or past the end is range_not_satisfiable" do
      assert {:error, :range_not_satisfiable} = Local.get_range("proj1/file3/range.bin", 10, 1)
      assert {:error, :range_not_satisfiable} = Local.get_range("proj1/file3/range.bin", 50, 1)
    end

    test "a missing key is an error" do
      assert {:error, :enoent} = Local.get_range("nope/nope/nope.bin", 0, 1)
    end
  end
end
