defmodule OrcaHub.ConfigFile.JsonTest do
  @moduledoc """
  JSON adapter coverage for `OrcaHub.ConfigFile` — ordered round-trip
  preservation (key order + untouched keys survive unchanged), the
  set/delete/add ops (including nested object paths and array indices),
  and graceful parse-error degradation.
  """
  use ExUnit.Case, async: true

  alias OrcaHub.ConfigFile

  @sample """
  {
    "zeta": 1,
    "alpha": {
      "nested": true,
      "list": ["a", "b", "c"]
    },
    "beta": [1, 2, 3]
  }
  """

  describe "parse/1" do
    test "decodes into a normalized tree with paths and value types" do
      assert {:ok, tree} = ConfigFile.parse(:json, @sample)
      assert tree.kind == :object
      assert tree.path == []
      assert Enum.map(tree.entries, fn {k, _} -> k end) == ["zeta", "alpha", "beta"]

      {"alpha", alpha} = List.keyfind(tree.entries, "alpha", 0)
      assert alpha.kind == :object
      assert alpha.path == ["alpha"]

      {"nested", nested} = List.keyfind(alpha.entries, "nested", 0)

      assert nested == %{
               kind: :leaf,
               path: ["alpha", "nested"],
               value: true,
               value_type: :boolean
             }

      {"list", list} = List.keyfind(alpha.entries, "list", 0)
      assert list.kind == :array
      assert list.path == ["alpha", "list"]
      assert Enum.map(list.items, & &1.value) == ["a", "b", "c"]

      assert Enum.map(list.items, & &1.path) == [
               ["alpha", "list", 0],
               ["alpha", "list", 1],
               ["alpha", "list", 2]
             ]
    end

    test "infers value_type for every JSON scalar kind" do
      {:ok, tree} =
        ConfigFile.parse(:json, ~s({"s": "x", "i": 1, "f": 1.5, "b": true, "n": null}))

      types = Map.new(tree.entries, fn {k, v} -> {k, v.value_type} end)

      assert types == %{
               "s" => :string,
               "i" => :integer,
               "f" => :float,
               "b" => :boolean,
               "n" => :null
             }
    end

    test "returns a descriptive error for malformed JSON instead of raising" do
      assert {:error, reason} = ConfigFile.parse(:json, "{not json")
      assert is_binary(reason)
    end
  end

  describe "apply_op/2 :set" do
    test "replaces a top-level scalar and preserves key order + untouched siblings" do
      assert {:ok, new_raw} = ConfigFile.apply_op(:json, @sample, {:set, ["zeta"], 99})
      assert {:ok, decoded} = Jason.decode(new_raw, objects: :ordered_objects)
      assert Enum.map(decoded.values, fn {k, _} -> k end) == ["zeta", "alpha", "beta"]
      assert List.keyfind(decoded.values, "zeta", 0) == {"zeta", 99}
      # untouched nested content survives byte-for-byte in shape
      {"alpha", alpha} = List.keyfind(decoded.values, "alpha", 0)
      assert List.keyfind(alpha.values, "nested", 0) == {"nested", true}
    end

    test "replaces a nested object value" do
      {:ok, new_raw} = ConfigFile.apply_op(:json, @sample, {:set, ["alpha", "nested"], false})
      {:ok, tree} = ConfigFile.parse(:json, new_raw)
      assert ConfigFile.get_node(tree, ["alpha", "nested"]).value == false
    end

    test "replaces an array element by index" do
      {:ok, new_raw} = ConfigFile.apply_op(:json, @sample, {:set, ["beta", 1], 42})
      {:ok, tree} = ConfigFile.parse(:json, new_raw)
      assert Enum.map(ConfigFile.get_node(tree, ["beta"]).items, & &1.value) == [1, 42, 3]
    end

    test "replaces a string inside a nested array" do
      {:ok, new_raw} = ConfigFile.apply_op(:json, @sample, {:set, ["alpha", "list", 0], "z"})
      {:ok, tree} = ConfigFile.parse(:json, new_raw)

      assert Enum.map(ConfigFile.get_node(tree, ["alpha", "list"]).items, & &1.value) == [
               "z",
               "b",
               "c"
             ]
    end

    test "errors on a path that doesn't exist" do
      assert ConfigFile.apply_op(:json, @sample, {:set, ["missing"], 1}) ==
               {:error, {:not_found, "missing"}}

      assert ConfigFile.apply_op(:json, @sample, {:set, ["beta", 99], 1}) ==
               {:error, {:not_found, 99}}
    end
  end

  describe "apply_op/2 :delete" do
    test "removes a top-level key, preserving the rest" do
      {:ok, new_raw} = ConfigFile.apply_op(:json, @sample, {:delete, ["zeta"]})
      {:ok, tree} = ConfigFile.parse(:json, new_raw)
      assert Enum.map(tree.entries, fn {k, _} -> k end) == ["alpha", "beta"]
    end

    test "removes an array element and shifts the remaining indices" do
      {:ok, new_raw} = ConfigFile.apply_op(:json, @sample, {:delete, ["beta", 0]})
      {:ok, tree} = ConfigFile.parse(:json, new_raw)
      assert Enum.map(ConfigFile.get_node(tree, ["beta"]).items, & &1.value) == [2, 3]
    end

    test "removes a nested object key" do
      {:ok, new_raw} = ConfigFile.apply_op(:json, @sample, {:delete, ["alpha", "nested"]})
      {:ok, tree} = ConfigFile.parse(:json, new_raw)
      alpha = ConfigFile.get_node(tree, ["alpha"])
      assert Enum.map(alpha.entries, fn {k, _} -> k end) == ["list"]
    end

    test "errors on a path that doesn't exist" do
      assert ConfigFile.apply_op(:json, @sample, {:delete, ["missing"]}) ==
               {:error, {:not_found, "missing"}}
    end
  end

  describe "apply_op/2 :add" do
    test "appends a new key to an object, at the end, preserving existing order" do
      {:ok, new_raw} = ConfigFile.apply_op(:json, @sample, {:add, [], "gamma", "new"})
      {:ok, tree} = ConfigFile.parse(:json, new_raw)
      assert Enum.map(tree.entries, fn {k, _} -> k end) == ["zeta", "alpha", "beta", "gamma"]
      assert ConfigFile.get_node(tree, ["gamma"]).value == "new"
    end

    test "appends a value to an array" do
      {:ok, new_raw} = ConfigFile.apply_op(:json, @sample, {:add, ["beta"], nil, 4})
      {:ok, tree} = ConfigFile.parse(:json, new_raw)
      assert Enum.map(ConfigFile.get_node(tree, ["beta"]).items, & &1.value) == [1, 2, 3, 4]
    end

    test "adds a key inside a nested object" do
      {:ok, new_raw} = ConfigFile.apply_op(:json, @sample, {:add, ["alpha"], "extra", 1})
      {:ok, tree} = ConfigFile.parse(:json, new_raw)
      alpha = ConfigFile.get_node(tree, ["alpha"])
      assert Enum.map(alpha.entries, fn {k, _} -> k end) == ["nested", "list", "extra"]
    end

    test "errors when the key already exists" do
      assert ConfigFile.apply_op(:json, @sample, {:add, [], "zeta", 1}) ==
               {:error, :already_exists}
    end
  end

  describe "parse-error degradation for apply_op/2" do
    test "malformed JSON never crashes, returns an error instead" do
      assert {:error, _reason} = ConfigFile.apply_op(:json, "{broken", {:set, ["a"], 1})
    end
  end

  describe "full round trip" do
    test "a chain of ops leaves untouched data exactly as it was" do
      {:ok, r1} = ConfigFile.apply_op(:json, @sample, {:set, ["zeta"], 2})
      {:ok, r2} = ConfigFile.apply_op(:json, r1, {:add, ["alpha"], "flag", false})
      {:ok, r3} = ConfigFile.apply_op(:json, r2, {:delete, ["beta", 2]})

      {:ok, tree} = ConfigFile.parse(:json, r3)
      assert ConfigFile.get_node(tree, ["zeta"]).value == 2
      assert ConfigFile.get_node(tree, ["alpha", "flag"]).value == false
      assert ConfigFile.get_node(tree, ["alpha", "nested"]).value == true

      assert Enum.map(ConfigFile.get_node(tree, ["alpha", "list"]).items, & &1.value) == [
               "a",
               "b",
               "c"
             ]

      assert Enum.map(ConfigFile.get_node(tree, ["beta"]).items, & &1.value) == [1, 2]
    end
  end
end
