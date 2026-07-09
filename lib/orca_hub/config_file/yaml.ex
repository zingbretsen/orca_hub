defmodule OrcaHub.ConfigFile.Yaml do
  @moduledoc """
  YAML adapter for `OrcaHub.ConfigFile`, backing `.yml`/`.yaml` files in the
  project file viewer (no catalog entry uses `:yaml` today — Codex's
  `config.toml` is the only Nodes-page format that isn't JSON).

  Decoding uses `yaml_elixir` (~> 2.11, native Erlang `:yamerl` under the
  hood, no NIF). Like TOML's plain-map decode, this loses key order —
  `parse/1` recovers it with a best-effort indentation-based line scan
  (`scan/1`): a `key:` line with nothing after the colon opens a nested
  block whose children are whatever's indented deeper than it, until a line
  at or above its own indent closes it. Any key the scanner can't place
  this way (sequence-of-mappings elements, flow collections) falls back to
  sorted order — display-only, so an imperfect scan just looks slightly
  off rather than crashing.

  `apply_op/2` holds to the same "second, simpler bar" than TOML's spec
  calls for — the common config shape only: block-style mappings and block
  or flow scalar values, consistent indentation. It edits the exact line(s)
  a path resolves to and **always re-parses the result and checks the
  target holds the expected value before returning it**; on any mismatch
  (including the scanner having misattributed a line) the original text is
  returned as an error instead of guessing.

  Deliberately unsupported (returns `{:error, :unsupported_structure}`):

    * anchors/aliases (`&x`, `*x`)
    * flow collections (`{a: 1}`, `[1, 2]`) — including editing an element
      inside one; only block style is edited surgically
    * multi-line scalars (`|`, `>` block scalars)
    * multiple documents (`---` separators) — `yaml_elixir` itself only
      ever returns the LAST document for a multi-document file, so parsing
      already silently narrows to one document; this adapter doesn't add
      extra detection on top of that, so treat multi-document files as
      generally unsupported for structured editing
    * any op touching a sequence that contains at least one mapping element
      (a "sequence of mappings") — by index, or (for `:add`) appending a
      new element to one
  """

  @behaviour OrcaHub.ConfigFile.Format

  alias OrcaHub.ConfigFile

  @kv_rx ~r/^(\s*)((?:[A-Za-z0-9_.\/-]+)|"[^"]*"|'[^']*'):(?:[ \t](.*))?$/

  @impl true
  def parse(raw) do
    with {:ok, decoded} <- decode(raw) do
      scanned = scan(raw)
      {:ok, to_tree(decoded, scanned.order, [])}
    end
  end

  @impl true
  def apply_op(raw, op) do
    with {:ok, decoded} <- decode(raw) do
      scanned = scan(raw)
      tree = to_tree(decoded, scanned.order, [])

      case run_op(raw, scanned, tree, op) do
        {:ok, new_raw} -> verify(new_raw, op, tree)
        {:error, _} = error -> error
      end
    end
  end

  defp decode(raw) do
    case YamlElixir.read_from_string(raw) do
      {:ok, decoded} when is_map(decoded) -> {:ok, decoded}
      {:ok, _other} -> {:error, "top-level YAML value must be a mapping"}
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  defp verify(new_raw, op, old_tree) do
    case parse(new_raw) do
      {:ok, tree} ->
        if op_applied?(tree, op, old_tree),
          do: {:ok, new_raw},
          else: {:error, :edit_verification_failed}

      {:error, _} ->
        {:error, :edit_verification_failed}
    end
  end

  defp op_applied?(tree, {:set, path, value}, _old_tree) do
    match?(%{kind: :leaf, value: ^value}, ConfigFile.get_node(tree, path))
  end

  defp op_applied?(tree, {:delete, path}, old_tree) do
    last = List.last(path)
    parent_path = Enum.drop(path, -1)

    case {is_integer(last), ConfigFile.get_node(old_tree, parent_path)} do
      {true, %{kind: :array, items: old_items}} ->
        case ConfigFile.get_node(tree, parent_path) do
          %{kind: :array, items: new_items} -> length(new_items) == length(old_items) - 1
          _ -> false
        end

      _ ->
        ConfigFile.get_node(tree, path) == nil
    end
  end

  defp op_applied?(tree, {:add, parent_path, nil, value}, _old_tree) do
    case ConfigFile.get_node(tree, parent_path) do
      %{kind: :array, items: [_ | _] = items} -> match?(%{value: ^value}, List.last(items))
      _ -> false
    end
  end

  defp op_applied?(tree, {:add, parent_path, key, value}, _old_tree) do
    match?(%{kind: :leaf, value: ^value}, ConfigFile.get_node(tree, parent_path ++ [key]))
  end

  # -------------------------------------------------------------------
  # Decoded structure + scanned order -> normalized tree
  # -------------------------------------------------------------------

  defp to_tree(map, order, path) when is_map(map) do
    keys = ordered_keys(map, order, path)

    entries =
      Enum.map(keys, fn key -> {key, to_tree(Map.fetch!(map, key), order, path ++ [key])} end)

    %{kind: :object, path: path, entries: entries}
  end

  defp to_tree(list, order, path) when is_list(list) do
    items = list |> Enum.with_index() |> Enum.map(fn {v, i} -> to_tree(v, order, path ++ [i]) end)
    %{kind: :array, path: path, items: items}
  end

  defp to_tree(value, _order, path) do
    {norm_value, type} = normalize_leaf(value)
    %{kind: :leaf, path: path, value: norm_value, value_type: type}
  end

  defp ordered_keys(map, order, path) do
    known = order |> Map.get(path, []) |> Enum.filter(&Map.has_key?(map, &1))
    known ++ Enum.sort(Map.keys(map) -- known)
  end

  defp normalize_leaf(v) when is_binary(v), do: {v, :string}
  defp normalize_leaf(v) when is_boolean(v), do: {v, :boolean}
  defp normalize_leaf(v) when is_integer(v), do: {v, :integer}
  defp normalize_leaf(v) when is_float(v), do: {v, :float}
  defp normalize_leaf(nil), do: {nil, :null}
  defp normalize_leaf(v), do: {inspect(v), :string}

  # -------------------------------------------------------------------
  # Line scan — indentation-based (no self-describing headers like TOML).
  # `stack` holds `{indent, path}` for every currently-open block, innermost
  # first; a new `key:` line pops stack entries at >= its own indent to find
  # its real parent, then either registers a `kv_lines` leaf (value present
  # on the same line) or opens a new block (`block_lines`, value empty —
  # children follow at greater indent).
  # -------------------------------------------------------------------

  defp scan(raw) do
    lines = String.split(raw, "\n")

    lines
    |> Enum.with_index()
    |> Enum.reduce(initial_scan_state(), fn {line, idx}, state -> scan_line(line, idx, state) end)
  end

  defp initial_scan_state, do: %{order: %{}, kv_lines: %{}, block_lines: %{}, stack: []}

  defp scan_line(raw_line, idx, state) do
    line = String.trim_trailing(raw_line)
    trimmed = String.trim_leading(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") or trimmed in ["---", "..."] ->
        state

      String.starts_with?(trimmed, "- ") or trimmed == "-" ->
        state

      match = Regex.run(@kv_rx, line) ->
        scan_kv(match, idx, state)

      true ->
        state
    end
  end

  defp scan_kv(match, idx, state) do
    [_, indent_str, key_text, rest] = pad_match(match, 4)
    indent = String.length(indent_str)
    key = unquote_yaml_key(key_text)

    stack = Enum.drop_while(state.stack, fn {stack_indent, _path} -> stack_indent >= indent end)

    parent_path =
      case stack do
        [{_indent, path} | _] -> path
        [] -> []
      end

    full_path = parent_path ++ [key]

    order = append_child(state.order, parent_path, key)
    {value_text, _comment} = split_yaml_comment(rest || "")
    value_text = String.trim(value_text)

    state = %{state | order: order, stack: stack}

    if value_text == "" do
      %{
        state
        | block_lines: Map.put(state.block_lines, full_path, {idx, indent}),
          stack: [{indent, full_path} | stack]
      }
    else
      %{state | kv_lines: Map.put(state.kv_lines, full_path, idx)}
    end
  end

  defp pad_match(match, size) when length(match) >= size, do: Enum.take(match, size)
  defp pad_match(match, size), do: match ++ List.duplicate(nil, size - length(match))

  defp unquote_yaml_key(text) do
    cond do
      String.starts_with?(text, "\"") and String.ends_with?(text, "\"") and
          String.length(text) >= 2 ->
        String.slice(text, 1..-2//1)

      String.starts_with?(text, "'") and String.ends_with?(text, "'") and String.length(text) >= 2 ->
        String.slice(text, 1..-2//1)

      true ->
        text
    end
  end

  defp append_child(order, parent_path, child_key) do
    Map.update(order, parent_path, [child_key], fn existing ->
      if child_key in existing, do: existing, else: existing ++ [child_key]
    end)
  end

  # -------------------------------------------------------------------
  # apply_op/2 dispatch
  # -------------------------------------------------------------------

  defp run_op(raw, scanned, tree, {:set, path, value}) do
    case ConfigFile.get_node(tree, path) do
      nil -> {:error, {:not_found, List.last(path)}}
      %{kind: :leaf} -> set_leaf(raw, scanned, tree, path, value)
      _ -> {:error, :unsupported_structure}
    end
  end

  defp run_op(raw, scanned, tree, {:delete, path}) do
    case ConfigFile.get_node(tree, path) do
      nil -> {:error, {:not_found, List.last(path)}}
      _ -> delete_node(raw, scanned, tree, path)
    end
  end

  defp run_op(raw, scanned, tree, {:add, parent_path, key, value}) do
    case ConfigFile.get_node(tree, parent_path) do
      nil ->
        {:error, {:not_found, List.last(parent_path)}}

      %{kind: :object} when is_binary(key) ->
        if ConfigFile.get_node(tree, parent_path ++ [key]) do
          {:error, :already_exists}
        else
          add_object_key(raw, scanned, parent_path, key, value)
        end

      %{kind: :array, items: items} when is_nil(key) ->
        if Enum.any?(items, &(&1.kind == :object)) do
          {:error, :unsupported_structure}
        else
          add_array_item(raw, scanned, parent_path, value)
        end

      _ ->
        {:error, :unsupported_structure}
    end
  end

  # -------------------------------------------------------------------
  # :set
  # -------------------------------------------------------------------

  defp set_leaf(raw, scanned, tree, path, value) do
    parent = Enum.drop(path, -1)
    last = List.last(path)

    cond do
      Map.has_key?(scanned.kv_lines, path) ->
        with {:ok, literal} <- serialize_yaml_value(value) do
          rewrite_kv_line(raw, Map.fetch!(scanned.kv_lines, path), literal)
        end

      is_integer(last) and scalar_sequence?(tree, parent) ->
        with {:ok, literal} <- serialize_yaml_value(value),
             {:ok, {start_idx, end_idx}} <- block_span(scanned, raw, parent),
             {:ok, item_lines} <- fetch_sequence_item(raw, start_idx, end_idx, last) do
          rewrite_sequence_item_line(raw, item_lines, literal)
        end

      true ->
        {:error, :unsupported_structure}
    end
  end

  defp scalar_sequence?(tree, path) do
    case ConfigFile.get_node(tree, path) do
      %{kind: :array, items: items} -> Enum.all?(items, &(&1.kind == :leaf))
      _ -> false
    end
  end

  # -------------------------------------------------------------------
  # :delete
  # -------------------------------------------------------------------

  defp delete_node(raw, scanned, tree, path) do
    parent = Enum.drop(path, -1)
    last = List.last(path)

    cond do
      is_integer(last) and not scalar_sequence?(tree, parent) and array_path?(tree, parent) ->
        {:error, :unsupported_structure}

      is_integer(last) and scalar_sequence?(tree, parent) ->
        with {:ok, {start_idx, end_idx}} <- block_span(scanned, raw, parent),
             {:ok, item_line} <- fetch_sequence_item(raw, start_idx, end_idx, last) do
          delete_single_line(raw, item_line)
        end

      block = Map.get(scanned.block_lines, path) ->
        {line_idx, indent} = block
        end_idx = block_end(raw, line_idx, indent)
        delete_line_span(raw, line_idx, end_idx)

      Map.has_key?(scanned.kv_lines, path) ->
        delete_single_line(raw, Map.fetch!(scanned.kv_lines, path))

      true ->
        {:error, :unsupported_structure}
    end
  end

  defp array_path?(tree, path), do: match?(%{kind: :array}, ConfigFile.get_node(tree, path))

  defp delete_single_line(raw, line_idx), do: delete_line_span(raw, line_idx, line_idx + 1)

  defp delete_line_span(raw, start_idx, end_idx) do
    lines = String.split(raw, "\n")
    {:ok, lines |> remove_line_range(start_idx, end_idx) |> Enum.join("\n")}
  end

  defp remove_line_range(lines, start_idx, end_idx) do
    lines
    |> Enum.with_index()
    |> Enum.reject(fn {_line, idx} -> idx >= start_idx and idx < end_idx end)
    |> Enum.map(&elem(&1, 0))
  end

  # -------------------------------------------------------------------
  # :add
  # -------------------------------------------------------------------

  defp add_object_key(raw, _scanned, [], key, value) do
    with {:ok, literal} <- serialize_yaml_value(value) do
      lines = String.split(raw, "\n")
      new_line = "#{key}: #{literal}"
      {:ok, lines |> List.insert_at(length(lines), new_line) |> Enum.join("\n")}
    end
  end

  defp add_object_key(raw, scanned, parent_path, key, value) do
    with {:ok, literal} <- serialize_yaml_value(value) do
      case Map.get(scanned.block_lines, parent_path) do
        {line_idx, indent} ->
          insert_idx = block_end(raw, line_idx, indent)
          child_indent = infer_child_indent(scanned, raw, parent_path, indent)
          new_line = String.duplicate(" ", child_indent) <> "#{key}: #{literal}"
          lines = String.split(raw, "\n")
          {:ok, lines |> List.insert_at(insert_idx, new_line) |> Enum.join("\n")}

        nil ->
          {:error, :unsupported_structure}
      end
    end
  end

  defp add_array_item(raw, scanned, parent_path, value) do
    with {:ok, literal} <- serialize_yaml_value(value),
         {:ok, {start_idx, end_idx}} <- block_span(scanned, raw, parent_path) do
      lines = String.split(raw, "\n")
      {_bidx, key_indent} = Map.fetch!(scanned.block_lines, parent_path)
      item_indent = infer_sequence_item_indent(lines, start_idx, end_idx, key_indent)
      new_line = String.duplicate(" ", item_indent) <> "- " <> literal
      {:ok, lines |> List.insert_at(end_idx, new_line) |> Enum.join("\n")}
    end
  end

  defp block_span(scanned, raw, path) do
    case Map.get(scanned.block_lines, path) do
      {line_idx, indent} -> {:ok, {line_idx + 1, block_end(raw, line_idx, indent)}}
      nil -> {:error, :unsupported_structure}
    end
  end

  defp fetch_sequence_item(raw, start_idx, end_idx, index) do
    lines = String.split(raw, "\n")

    item_lines =
      start_idx..(end_idx - 1)//1
      |> Enum.to_list()
      |> Enum.filter(fn idx ->
        trimmed = lines |> Enum.at(idx) |> String.trim()
        String.starts_with?(trimmed, "- ") or trimmed == "-"
      end)

    case Enum.at(item_lines, index) do
      nil -> {:error, {:not_found, index}}
      line_idx -> {:ok, line_idx}
    end
  end

  defp infer_sequence_item_indent(lines, start_idx, end_idx, key_indent) do
    start_idx..(end_idx - 1)//1
    |> Enum.find_value(fn idx ->
      line = Enum.at(lines, idx)
      trimmed = String.trim(line)
      if String.starts_with?(trimmed, "- ") or trimmed == "-", do: indent_of(line)
    end) || key_indent + 2
  end

  defp infer_child_indent(scanned, raw, parent_path, parent_indent) do
    case Map.get(scanned.order, parent_path) do
      [first_child | _] ->
        full = parent_path ++ [first_child]

        line_idx =
          Map.get(scanned.kv_lines, full) ||
            case Map.get(scanned.block_lines, full) do
              {idx, _indent} -> idx
              nil -> nil
            end

        case line_idx do
          nil -> parent_indent + 2
          idx -> raw |> String.split("\n") |> Enum.at(idx) |> indent_of()
        end

      _ ->
        parent_indent + 2
    end
  end

  # A block's content ends at the first subsequent non-blank, non-comment
  # line whose indent is <= the key's own indent (or EOF) — nested children
  # are, by construction, always indented deeper, so this naturally covers
  # the whole subtree in one boundary (unlike TOML, no separate "own range"
  # vs "full range" distinction is needed).
  defp block_end(raw, header_idx, indent) do
    lines = String.split(raw, "\n")

    lines
    |> Enum.with_index()
    |> Enum.drop(header_idx + 1)
    |> Enum.find(fn {line, _idx} ->
      trimmed = String.trim(line)
      trimmed != "" and not String.starts_with?(trimmed, "#") and indent_of(line) <= indent
    end)
    |> case do
      {_line, idx} -> idx
      nil -> length(lines)
    end
  end

  defp indent_of(line), do: String.length(line) - String.length(String.trim_leading(line))

  # -------------------------------------------------------------------
  # Single-line rewrite helpers
  # -------------------------------------------------------------------

  defp rewrite_kv_line(raw, line_idx, literal) do
    lines = String.split(raw, "\n")
    line = Enum.at(lines, line_idx) |> String.trim_trailing()

    case Regex.run(@kv_rx, line) do
      match when is_list(match) ->
        [_, indent, key_text, rest] = pad_match(match, 4)
        {_value, comment} = split_yaml_comment(rest || "")
        new_line = indent <> key_text <> ": " <> literal <> yaml_comment_suffix(comment)
        {:ok, lines |> List.replace_at(line_idx, new_line) |> Enum.join("\n")}

      nil ->
        {:error, :unsupported_structure}
    end
  end

  defp rewrite_sequence_item_line(raw, line_idx, literal) do
    lines = String.split(raw, "\n")
    line = Enum.at(lines, line_idx)
    indent = indent_of(line)
    trimmed = String.trim_leading(line)
    rest = if String.starts_with?(trimmed, "- "), do: String.slice(trimmed, 2..-1//1), else: ""
    {_value, comment} = split_yaml_comment(rest)
    new_line = String.duplicate(" ", indent) <> "- " <> literal <> yaml_comment_suffix(comment)
    {:ok, lines |> List.replace_at(line_idx, new_line) |> Enum.join("\n")}
  end

  defp yaml_comment_suffix(nil), do: ""
  defp yaml_comment_suffix(comment), do: "  " <> comment

  # `#` starts a comment only when preceded by whitespace (or is the first
  # character) and outside a quoted string — YAML plain scalars can contain
  # `#` mid-token (e.g. a URL fragment) without it being a comment.
  defp split_yaml_comment(text), do: scan_yaml_comment(text, 0, false, nil, true)

  defp scan_yaml_comment(text, idx, in_quote, quote_char, prev_space?) do
    len = String.length(text)

    if idx >= len do
      {text, nil}
    else
      ch = String.at(text, idx)

      cond do
        in_quote and quote_char == "\"" and ch == "\\" ->
          scan_yaml_comment(text, idx + 2, in_quote, quote_char, false)

        in_quote and ch == quote_char ->
          scan_yaml_comment(text, idx + 1, false, nil, false)

        in_quote ->
          scan_yaml_comment(text, idx + 1, in_quote, quote_char, false)

        ch in ["\"", "'"] ->
          scan_yaml_comment(text, idx + 1, true, ch, false)

        ch == "#" and prev_space? ->
          {String.slice(text, 0, idx), String.slice(text, idx, len - idx)}

        true ->
          scan_yaml_comment(text, idx + 1, in_quote, quote_char, ch in [" ", "\t"])
      end
    end
  end

  # -------------------------------------------------------------------
  # Value serialization — always quoted for strings (matching the TOML
  # adapter's choice), sidestepping YAML plain-scalar ambiguity (a bare
  # `yes`/`no`/`on`/`off`/`null`/numeric-looking string would otherwise
  # silently change type on the next parse).
  # -------------------------------------------------------------------

  defp serialize_yaml_value(nil), do: {:ok, "null"}
  defp serialize_yaml_value(v) when is_boolean(v), do: {:ok, to_string(v)}
  defp serialize_yaml_value(v) when is_integer(v), do: {:ok, Integer.to_string(v)}
  defp serialize_yaml_value(v) when is_float(v), do: {:ok, Float.to_string(v)}
  defp serialize_yaml_value(v) when is_binary(v), do: {:ok, encode_yaml_string(v)}
  defp serialize_yaml_value(_v), do: {:error, :unsupported_value}

  defp encode_yaml_string(v) do
    escaped =
      v
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\t", "\\t")

    "\"" <> escaped <> "\""
  end
end
