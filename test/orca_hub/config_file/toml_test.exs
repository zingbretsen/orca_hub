defmodule OrcaHub.ConfigFile.TomlTest do
  @moduledoc """
  TOML adapter coverage for `OrcaHub.ConfigFile` — order recovery via the
  raw-text scan, the set/delete/add ops (including nested tables, array-
  of-tables, and single-line scalar arrays), comment/formatting
  preservation (the whole reason `apply_op/2` is a surgical text edit
  rather than a parse/mutate/re-dump), corruption-guard behavior for
  constructs the adapter deliberately doesn't support, and graceful
  parse-error degradation.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.ConfigFile

  @sample """
  # top-level comment
  zeta = 1

  [alpha]
  nested = true
  list = ["a", "b", "c"]
  inline = { x = 1, y = 2 }

  [alpha.beta]
  deep = "hi"

  [[items]]
  name = "x"
  weight = 1

  [[items]]
  name = "y"
  weight = 2
  """

  describe "parse/1" do
    test "decodes into a normalized tree with paths and value types" do
      assert {:ok, tree} = ConfigFile.parse(:toml, @sample)
      assert tree.kind == :object
      assert tree.path == []
      assert Enum.map(tree.entries, fn {k, _} -> k end) == ["zeta", "alpha", "items"]

      {"alpha", alpha} = List.keyfind(tree.entries, "alpha", 0)
      assert alpha.kind == :object
      assert alpha.path == ["alpha"]
      assert Enum.map(alpha.entries, fn {k, _} -> k end) == ["nested", "list", "inline", "beta"]

      {"nested", nested} = List.keyfind(alpha.entries, "nested", 0)

      assert nested == %{
               kind: :leaf,
               path: ["alpha", "nested"],
               value: true,
               value_type: :boolean
             }

      {"list", list} = List.keyfind(alpha.entries, "list", 0)
      assert list.kind == :array
      assert Enum.map(list.items, & &1.value) == ["a", "b", "c"]
    end

    test "recovers array-of-tables as an ordered list of objects" do
      {:ok, tree} = ConfigFile.parse(:toml, @sample)
      items = ConfigFile.get_node(tree, ["items"])
      assert items.kind == :array
      assert Enum.map(items.items, & &1.path) == [["items", 0], ["items", 1]]
      assert ConfigFile.get_node(tree, ["items", 0, "name"]).value == "x"
      assert ConfigFile.get_node(tree, ["items", 1, "name"]).value == "y"
    end

    test "recovers dotted-header nested table order" do
      {:ok, tree} = ConfigFile.parse(:toml, @sample)
      assert ConfigFile.get_node(tree, ["alpha", "beta", "deep"]).value == "hi"
    end

    test "infers value_type for every scalar kind, including dates as strings" do
      {:ok, tree} =
        ConfigFile.parse(:toml, ~s(s = "x"\ni = 1\nf = 1.5\nb = true\nd = 2024-01-01\n))

      types = Map.new(tree.entries, fn {k, v} -> {k, v.value_type} end)

      assert types == %{
               "s" => :string,
               "i" => :integer,
               "f" => :float,
               "b" => :boolean,
               "d" => :string
             }

      assert ConfigFile.get_node(tree, ["d"]).value == "2024-01-01"
    end

    test "returns a descriptive error for malformed TOML instead of raising" do
      assert {:error, reason} = ConfigFile.parse(:toml, "not = [valid")
      assert is_binary(reason)
    end
  end

  describe "apply_op/2 :set" do
    test "replaces a top-level scalar, preserving every other line byte-for-byte" do
      assert {:ok, new_raw} = ConfigFile.apply_op(:toml, @sample, {:set, ["zeta"], 99})
      old_lines = String.split(@sample, "\n")
      new_lines = String.split(new_raw, "\n")

      assert Enum.at(new_lines, 1) == "zeta = 99"

      for idx <- 0..(length(old_lines) - 1), idx != 1 do
        assert Enum.at(new_lines, idx) == Enum.at(old_lines, idx)
      end
    end

    test "replaces a nested table value" do
      {:ok, new_raw} = ConfigFile.apply_op(:toml, @sample, {:set, ["alpha", "nested"], false})
      {:ok, tree} = ConfigFile.parse(:toml, new_raw)
      assert ConfigFile.get_node(tree, ["alpha", "nested"]).value == false
    end

    test "replaces a leaf inside a specific array-of-tables occurrence" do
      {:ok, new_raw} = ConfigFile.apply_op(:toml, @sample, {:set, ["items", 1, "name"], "z"})
      {:ok, tree} = ConfigFile.parse(:toml, new_raw)
      assert ConfigFile.get_node(tree, ["items", 0, "name"]).value == "x"
      assert ConfigFile.get_node(tree, ["items", 1, "name"]).value == "z"
    end

    test "replaces an element of a single-line scalar array" do
      {:ok, new_raw} = ConfigFile.apply_op(:toml, @sample, {:set, ["alpha", "list", 1], "z"})
      {:ok, tree} = ConfigFile.parse(:toml, new_raw)

      assert Enum.map(ConfigFile.get_node(tree, ["alpha", "list"]).items, & &1.value) == [
               "a",
               "z",
               "c"
             ]
    end

    test "errors on a path that doesn't exist" do
      assert ConfigFile.apply_op(:toml, @sample, {:set, ["missing"], 1}) ==
               {:error, {:not_found, "missing"}}
    end

    test "errors setting a value to null — TOML has no null literal" do
      assert ConfigFile.apply_op(:toml, @sample, {:set, ["zeta"], nil}) ==
               {:error, :unsupported_value}
    end
  end

  describe "apply_op/2 :delete" do
    test "removes a top-level key" do
      {:ok, new_raw} = ConfigFile.apply_op(:toml, @sample, {:delete, ["zeta"]})
      {:ok, tree} = ConfigFile.parse(:toml, new_raw)
      refute List.keyfind(tree.entries, "zeta", 0)
    end

    test "deleting a table removes its own keys and nested sub-tables (whole range)" do
      {:ok, new_raw} = ConfigFile.apply_op(:toml, @sample, {:delete, ["alpha"]})
      {:ok, tree} = ConfigFile.parse(:toml, new_raw)
      refute List.keyfind(tree.entries, "alpha", 0)
      refute new_raw =~ "[alpha.beta]"
      refute new_raw =~ "deep"
      assert new_raw =~ "zeta = 1"
      assert new_raw =~ "[[items]]"
    end

    test "deleting the array-of-tables key removes every occurrence" do
      {:ok, new_raw} = ConfigFile.apply_op(:toml, @sample, {:delete, ["items"]})
      {:ok, tree} = ConfigFile.parse(:toml, new_raw)
      refute List.keyfind(tree.entries, "items", 0)
      refute new_raw =~ "[[items]]"
      assert new_raw =~ "[alpha]"
    end

    test "removes an array element and shifts remaining indices" do
      {:ok, new_raw} = ConfigFile.apply_op(:toml, @sample, {:delete, ["alpha", "list", 0]})
      {:ok, tree} = ConfigFile.parse(:toml, new_raw)

      assert Enum.map(ConfigFile.get_node(tree, ["alpha", "list"]).items, & &1.value) == [
               "b",
               "c"
             ]
    end

    test "errors on a path that doesn't exist" do
      assert ConfigFile.apply_op(:toml, @sample, {:delete, ["missing"]}) ==
               {:error, {:not_found, "missing"}}
    end
  end

  describe "apply_op/2 :add" do
    test "appends a new key at root, right before the first table header (TOML requires root keys precede any [table])" do
      {:ok, new_raw} = ConfigFile.apply_op(:toml, @sample, {:add, [], "gamma", "new"})
      {:ok, tree} = ConfigFile.parse(:toml, new_raw)
      assert Enum.map(tree.entries, fn {k, _} -> k end) == ["zeta", "gamma", "alpha", "items"]
      assert ConfigFile.get_node(tree, ["gamma"]).value == "new"
    end

    test "appends a key inside a nested table, before its own next header (its nested sub-table)" do
      {:ok, new_raw} = ConfigFile.apply_op(:toml, @sample, {:add, ["alpha"], "extra", 1})
      {:ok, tree} = ConfigFile.parse(:toml, new_raw)
      alpha = ConfigFile.get_node(tree, ["alpha"])

      assert Enum.map(alpha.entries, fn {k, _} -> k end) == [
               "nested",
               "list",
               "inline",
               "extra",
               "beta"
             ]

      assert ConfigFile.get_node(tree, ["alpha", "beta", "deep"]).value == "hi"
    end

    test "appends an element to a single-line scalar array" do
      {:ok, new_raw} = ConfigFile.apply_op(:toml, @sample, {:add, ["alpha", "list"], nil, "d"})
      {:ok, tree} = ConfigFile.parse(:toml, new_raw)

      assert Enum.map(ConfigFile.get_node(tree, ["alpha", "list"]).items, & &1.value) == [
               "a",
               "b",
               "c",
               "d"
             ]
    end

    test "appends a key to a single-line inline table" do
      {:ok, new_raw} = ConfigFile.apply_op(:toml, @sample, {:add, ["alpha", "inline"], "z", 3})
      {:ok, tree} = ConfigFile.parse(:toml, new_raw)
      inline = ConfigFile.get_node(tree, ["alpha", "inline"])
      assert ConfigFile.get_node(tree, ["alpha", "inline", "z"]).value == 3
      assert Enum.map(inline.entries, fn {k, _} -> k end) -- ["x", "y", "z"] == []
    end

    test "errors when the key already exists" do
      assert ConfigFile.apply_op(:toml, @sample, {:add, [], "zeta", 1}) ==
               {:error, :already_exists}
    end
  end

  describe "corruption guards — deliberately unsupported constructs" do
    test "setting a leaf nested inside an inline table is unsupported, original text untouched" do
      assert ConfigFile.apply_op(:toml, @sample, {:set, ["alpha", "inline", "x"], 99}) ==
               {:error, :unsupported_structure}

      assert {:ok, _} = ConfigFile.parse(:toml, @sample)
    end

    test "editing a leaf inside a multi-line array is unsupported, original text untouched" do
      raw = """
      list = [
        1,
        2,
      ]
      """

      assert ConfigFile.apply_op(:toml, raw, {:set, ["list", 0], 9}) ==
               {:error, :unsupported_structure}

      assert {:ok, _} = ConfigFile.parse(:toml, raw)
    end

    test "deleting a specific array-of-tables occurrence by index still round-trips safely" do
      {:ok, new_raw} = ConfigFile.apply_op(:toml, @sample, {:delete, ["items", 0]})
      {:ok, tree} = ConfigFile.parse(:toml, new_raw)
      items = ConfigFile.get_node(tree, ["items"])
      assert Enum.map(items.items, &ConfigFile.get_node(&1, ["name"]).value) == ["y"]
    end
  end

  describe "parse-error degradation for apply_op/2" do
    test "malformed TOML never crashes, returns an error instead" do
      assert {:error, _reason} = ConfigFile.apply_op(:toml, "not = [valid", {:set, ["a"], 1})
    end
  end

  describe "full round trip" do
    test "a chain of ops leaves untouched data exactly as it was" do
      {:ok, r1} = ConfigFile.apply_op(:toml, @sample, {:set, ["zeta"], 2})
      {:ok, r2} = ConfigFile.apply_op(:toml, r1, {:add, ["alpha"], "flag", false})
      {:ok, r3} = ConfigFile.apply_op(:toml, r2, {:delete, ["alpha", "list", 2]})

      {:ok, tree} = ConfigFile.parse(:toml, r3)
      assert ConfigFile.get_node(tree, ["zeta"]).value == 2
      assert ConfigFile.get_node(tree, ["alpha", "flag"]).value == false
      assert ConfigFile.get_node(tree, ["alpha", "nested"]).value == true

      assert Enum.map(ConfigFile.get_node(tree, ["alpha", "list"]).items, & &1.value) == [
               "a",
               "b"
             ]

      assert ConfigFile.get_node(tree, ["alpha", "beta", "deep"]).value == "hi"
      assert ConfigFile.get_node(tree, ["items", 0, "name"]).value == "x"
    end
  end
end
