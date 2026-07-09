defmodule OrcaHub.ConfigFile.YamlTest do
  @moduledoc """
  YAML adapter coverage for `OrcaHub.ConfigFile` — order recovery via the
  indentation-based raw-text scan, the set/delete/add ops for block-style
  mappings and scalar sequences, comment/formatting preservation, the
  explicit sequence-of-mappings / flow-style corruption guards, and
  graceful parse-error degradation.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.ConfigFile

  @sample """
  # top-level comment
  zeta: 1

  alpha:
    nested: true
    list:
      - a
      - b
      - c
    beta:
      deep: hi

  items:
    - name: x
      weight: 1
    - name: y
      weight: 2
  """

  describe "parse/1" do
    test "decodes into a normalized tree with paths and value types" do
      assert {:ok, tree} = ConfigFile.parse(:yaml, @sample)
      assert tree.kind == :object
      assert Enum.map(tree.entries, fn {k, _} -> k end) == ["zeta", "alpha", "items"]

      {"alpha", alpha} = List.keyfind(tree.entries, "alpha", 0)
      assert alpha.kind == :object
      assert Enum.map(alpha.entries, fn {k, _} -> k end) == ["nested", "list", "beta"]

      {"nested", nested} = List.keyfind(alpha.entries, "nested", 0)

      assert nested == %{
               kind: :leaf,
               path: ["alpha", "nested"],
               value: true,
               value_type: :boolean
             }
    end

    test "recovers nested block-mapping order and scalar sequence order" do
      {:ok, tree} = ConfigFile.parse(:yaml, @sample)
      assert ConfigFile.get_node(tree, ["alpha", "beta", "deep"]).value == "hi"
      list = ConfigFile.get_node(tree, ["alpha", "list"])
      assert Enum.map(list.items, & &1.value) == ["a", "b", "c"]
    end

    test "sequence-of-mappings decodes as an ordered list of objects" do
      {:ok, tree} = ConfigFile.parse(:yaml, @sample)
      items = ConfigFile.get_node(tree, ["items"])
      assert items.kind == :array
      assert ConfigFile.get_node(tree, ["items", 0, "name"]).value == "x"
      assert ConfigFile.get_node(tree, ["items", 1, "name"]).value == "y"
    end

    test "infers value_type for every scalar kind" do
      {:ok, tree} = ConfigFile.parse(:yaml, "s: x\ni: 1\nf: 1.5\nb: true\nn: null\n")
      types = Map.new(tree.entries, fn {k, v} -> {k, v.value_type} end)

      assert types == %{
               "s" => :string,
               "i" => :integer,
               "f" => :float,
               "b" => :boolean,
               "n" => :null
             }
    end

    test "returns a descriptive error for malformed YAML instead of raising" do
      assert {:error, reason} = ConfigFile.parse(:yaml, "a: [1, 2")
      assert is_binary(reason)
    end

    test "returns an error when the top-level document isn't a mapping" do
      assert {:error, reason} = ConfigFile.parse(:yaml, "- a\n- b\n")
      assert is_binary(reason)
    end
  end

  describe "apply_op/2 :set" do
    test "replaces a top-level scalar, preserving every other line byte-for-byte" do
      assert {:ok, new_raw} = ConfigFile.apply_op(:yaml, @sample, {:set, ["zeta"], 99})
      old_lines = String.split(@sample, "\n")
      new_lines = String.split(new_raw, "\n")

      assert Enum.at(new_lines, 1) == "zeta: 99"

      for idx <- 0..(length(old_lines) - 1), idx != 1 do
        assert Enum.at(new_lines, idx) == Enum.at(old_lines, idx)
      end
    end

    test "replaces a nested mapping value" do
      {:ok, new_raw} = ConfigFile.apply_op(:yaml, @sample, {:set, ["alpha", "nested"], false})
      {:ok, tree} = ConfigFile.parse(:yaml, new_raw)
      assert ConfigFile.get_node(tree, ["alpha", "nested"]).value == false
    end

    test "replaces an element of a block-style scalar sequence" do
      {:ok, new_raw} = ConfigFile.apply_op(:yaml, @sample, {:set, ["alpha", "list", 1], "Z"})
      {:ok, tree} = ConfigFile.parse(:yaml, new_raw)

      assert Enum.map(ConfigFile.get_node(tree, ["alpha", "list"]).items, & &1.value) == [
               "a",
               "Z",
               "c"
             ]
    end

    test "errors on a path that doesn't exist" do
      assert ConfigFile.apply_op(:yaml, @sample, {:set, ["missing"], 1}) ==
               {:error, {:not_found, "missing"}}
    end

    test "setting a value to null is supported (unlike TOML)" do
      {:ok, new_raw} = ConfigFile.apply_op(:yaml, @sample, {:set, ["zeta"], nil})
      {:ok, tree} = ConfigFile.parse(:yaml, new_raw)
      assert ConfigFile.get_node(tree, ["zeta"]).value == nil
    end
  end

  describe "apply_op/2 :delete" do
    test "removes a top-level key" do
      {:ok, new_raw} = ConfigFile.apply_op(:yaml, @sample, {:delete, ["zeta"]})
      {:ok, tree} = ConfigFile.parse(:yaml, new_raw)
      refute List.keyfind(tree.entries, "zeta", 0)
    end

    test "deleting a mapping key removes its whole indented child block" do
      {:ok, new_raw} = ConfigFile.apply_op(:yaml, @sample, {:delete, ["alpha"]})
      {:ok, tree} = ConfigFile.parse(:yaml, new_raw)
      refute List.keyfind(tree.entries, "alpha", 0)
      refute new_raw =~ "nested"
      refute new_raw =~ "deep"
      assert new_raw =~ "zeta: 1"
      assert new_raw =~ "items:"
    end

    test "removes a scalar sequence element and shifts remaining indices" do
      {:ok, new_raw} = ConfigFile.apply_op(:yaml, @sample, {:delete, ["alpha", "list", 0]})
      {:ok, tree} = ConfigFile.parse(:yaml, new_raw)

      assert Enum.map(ConfigFile.get_node(tree, ["alpha", "list"]).items, & &1.value) == [
               "b",
               "c"
             ]
    end

    test "errors on a path that doesn't exist" do
      assert ConfigFile.apply_op(:yaml, @sample, {:delete, ["missing"]}) ==
               {:error, {:not_found, "missing"}}
    end
  end

  describe "apply_op/2 :add" do
    test "appends a new key at root" do
      {:ok, new_raw} = ConfigFile.apply_op(:yaml, @sample, {:add, [], "gamma", "new"})
      {:ok, tree} = ConfigFile.parse(:yaml, new_raw)
      assert ConfigFile.get_node(tree, ["gamma"]).value == "new"
    end

    test "appends a key inside a nested mapping, at the correct indent" do
      {:ok, new_raw} = ConfigFile.apply_op(:yaml, @sample, {:add, ["alpha"], "extra", 1})
      {:ok, tree} = ConfigFile.parse(:yaml, new_raw)
      assert ConfigFile.get_node(tree, ["alpha", "extra"]).value == 1
      assert ConfigFile.get_node(tree, ["alpha", "beta", "deep"]).value == "hi"
    end

    test "appends an element to a block-style scalar sequence" do
      {:ok, new_raw} = ConfigFile.apply_op(:yaml, @sample, {:add, ["alpha", "list"], nil, "d"})
      {:ok, tree} = ConfigFile.parse(:yaml, new_raw)

      assert Enum.map(ConfigFile.get_node(tree, ["alpha", "list"]).items, & &1.value) == [
               "a",
               "b",
               "c",
               "d"
             ]
    end

    test "errors when the key already exists" do
      assert ConfigFile.apply_op(:yaml, @sample, {:add, [], "zeta", 1}) ==
               {:error, :already_exists}
    end
  end

  describe "corruption guards — deliberately unsupported constructs" do
    test "editing an element of a sequence-of-mappings by index is unsupported" do
      assert ConfigFile.apply_op(:yaml, @sample, {:delete, ["items", 0]}) ==
               {:error, :unsupported_structure}

      assert {:ok, _} = ConfigFile.parse(:yaml, @sample)
    end

    test "editing a leaf nested inside a sequence-of-mappings element is unsupported" do
      assert ConfigFile.apply_op(:yaml, @sample, {:set, ["items", 0, "name"], "z"}) ==
               {:error, :unsupported_structure}
    end

    test "appending to a sequence-of-mappings is unsupported" do
      assert ConfigFile.apply_op(:yaml, @sample, {:add, ["items"], nil, "z"}) ==
               {:error, :unsupported_structure}
    end

    test "editing a value inside a flow-style mapping is unsupported, original text untouched" do
      raw = "flow: { a: 1, b: 2 }\n"

      assert ConfigFile.apply_op(:yaml, raw, {:set, ["flow", "a"], 9}) ==
               {:error, :unsupported_structure}

      assert {:ok, _} = ConfigFile.parse(:yaml, raw)
    end
  end

  describe "parse-error degradation for apply_op/2" do
    test "malformed YAML never crashes, returns an error instead" do
      assert {:error, _reason} = ConfigFile.apply_op(:yaml, "a: [1, 2", {:set, ["a"], 1})
    end
  end

  describe "full round trip" do
    test "a chain of ops leaves untouched data exactly as it was" do
      {:ok, r1} = ConfigFile.apply_op(:yaml, @sample, {:set, ["zeta"], 2})
      {:ok, r2} = ConfigFile.apply_op(:yaml, r1, {:add, ["alpha"], "flag", false})
      {:ok, r3} = ConfigFile.apply_op(:yaml, r2, {:delete, ["alpha", "list", 2]})

      {:ok, tree} = ConfigFile.parse(:yaml, r3)
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
