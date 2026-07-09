defmodule OrcaHub.ConfigFileTest do
  @moduledoc """
  Format-agnostic coverage for `OrcaHub.ConfigFile` — path encode/decode
  round-tripping, value coercion, and adapter dispatch. See
  `OrcaHub.ConfigFile.JsonTest` for the JSON adapter's own parse/apply_op
  coverage (round-trip preservation, ops, parse-error degradation).
  """
  use ExUnit.Case, async: true

  alias OrcaHub.ConfigFile

  describe "supported?/1" do
    test "true for a registered format" do
      assert ConfigFile.supported?(:json)
    end

    test "false for an unregistered format" do
      refute ConfigFile.supported?(:toml)
      refute ConfigFile.supported?(:yaml)
      refute ConfigFile.supported?(:markdown)
    end
  end

  describe "parse/2 and apply_op/3 for an unsupported format" do
    test "both return :unsupported_format rather than raising" do
      assert ConfigFile.parse(:toml, "a = 1") == {:error, :unsupported_format}

      assert ConfigFile.apply_op(:toml, "a = 1", {:set, ["a"], 2}) ==
               {:error, :unsupported_format}
    end
  end

  describe "encode_path/1 and decode_path/1" do
    test "round-trips a mix of string keys and integer indices" do
      path = ["permissions", "allow", 0, "nested key"]
      assert ConfigFile.decode_path(ConfigFile.encode_path(path)) == path
    end

    test "round-trips the empty path" do
      assert ConfigFile.decode_path(ConfigFile.encode_path([])) == []
    end

    test "round-trips keys containing the segment delimiter and other odd characters" do
      path = ["a.b.c", "key/with/slash", "unicode✓key"]
      assert ConfigFile.decode_path(ConfigFile.encode_path(path)) == path
    end
  end

  describe "coerce/2" do
    test "string passes through unchanged" do
      assert ConfigFile.coerce(:string, "hello") == {:ok, "hello"}
    end

    test "null ignores the input text" do
      assert ConfigFile.coerce(:null, "anything") == {:ok, nil}
    end

    test "boolean accepts common truthy spellings, everything else is false" do
      assert ConfigFile.coerce(:boolean, "true") == {:ok, true}
      assert ConfigFile.coerce(:boolean, "on") == {:ok, true}
      assert ConfigFile.coerce(:boolean, "false") == {:ok, false}
      assert ConfigFile.coerce(:boolean, "nonsense") == {:ok, false}
    end

    test "integer/float/number parse whichever numeric form the text actually is" do
      assert ConfigFile.coerce(:integer, "42") == {:ok, 42}
      assert ConfigFile.coerce(:float, "3.5") == {:ok, 3.5}
      assert ConfigFile.coerce(:number, "42") == {:ok, 42}
      assert ConfigFile.coerce(:number, "3.5") == {:ok, 3.5}
    end

    test "number rejects non-numeric text instead of silently truncating" do
      assert ConfigFile.coerce(:number, "abc") == {:error, :invalid_number}
      assert ConfigFile.coerce(:number, "12abc") == {:error, :invalid_number}
    end
  end

  describe "parse_value_type/1" do
    test "maps known form strings and defaults unknown ones to :string" do
      assert ConfigFile.parse_value_type("number") == :number
      assert ConfigFile.parse_value_type("boolean") == :boolean
      assert ConfigFile.parse_value_type("null") == :null
      assert ConfigFile.parse_value_type("string") == :string
      assert ConfigFile.parse_value_type("garbage") == :string
    end
  end

  describe "get_node/2" do
    setup do
      {:ok, tree} =
        ConfigFile.parse(:json, ~s({"a": {"b": [1, 2, {"c": true}]}, "top": "x"}))

      {:ok, tree: tree}
    end

    test "resolves the root with an empty path", %{tree: tree} do
      assert ConfigFile.get_node(tree, []) == tree
    end

    test "resolves a nested object key", %{tree: tree} do
      assert %{kind: :leaf, value: "x"} = ConfigFile.get_node(tree, ["top"])
    end

    test "resolves through an array index into a nested object", %{tree: tree} do
      assert %{kind: :leaf, value: true} = ConfigFile.get_node(tree, ["a", "b", 2, "c"])
    end

    test "returns nil for a missing key or out-of-range index", %{tree: tree} do
      assert ConfigFile.get_node(tree, ["missing"]) == nil
      assert ConfigFile.get_node(tree, ["a", "b", 99]) == nil
    end
  end
end
