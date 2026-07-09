defmodule OrcaHub.ConfigFile.Toml do
  @moduledoc """
  TOML adapter for `OrcaHub.ConfigFile`, backing Codex's `config.toml` in the
  Nodes page catalog (`OrcaHub.NodeConfig`) and `.toml` files in the project
  file viewer.

  Decoding uses the `toml` hex package (bitwalker/toml-elixir) — the only
  actively-maintained pure-Elixir TOML decoder on Hex with no NIF/Rust
  dependency (keeping the same "pure BEAM" deployment story as the rest of
  the app). It decodes into plain Elixir maps, which — unlike
  `Jason.OrderedObject` for JSON — lose key order. `parse/1` recovers
  document order with a best-effort line scan (`scan/1`) that walks
  `[table]` / `[[array-of-tables]]` headers and `key = value` lines to learn
  each object's child order; any key the scanner doesn't confidently attach
  (inline table members, dotted keys nested oddly, anything inside a
  multi-line array/inline-table) just falls back to sorted order. Since this
  order is display-only, an imperfect scan degrades to "slightly wrong
  order" rather than a crash.

  `apply_op/2` is the surgical text edit `OrcaHub.ConfigFile.Format` calls
  for — no parse/mutate/re-dump, since that would drop comments and
  formatting. It reuses the same line scan to locate the exact line (or
  table/array-table range) a path maps to, edits just that span, and
  **always re-parses the result and checks the target path holds the
  expected value before returning it** — if that check fails (including
  because the edit landed on the wrong line, e.g. from the scanner
  misreading a multi-line construct), the original text is never returned
  corrupted; an error is returned instead. This is the safety net for every
  shortcut taken below.

  Deliberately unsupported (returns `{:error, :unsupported_structure}`
  rather than risk corruption):

    * multi-line arrays, multi-line basic/literal strings (`\"""`, `'''`) —
      the line scanner suppresses kv/header matching while bracket-nesting
      is open across lines, but doesn't track triple-quoted strings, so a
      leaf inside one simply isn't found as an editable line
    * setting/adding a `:null` value — TOML has no null literal
    * replacing/deleting one occurrence of an array-of-tables *by whole
      value* is supported (the block is a normal header range), but
      appending a bare scalar to an array whose elements are tables
      (`[[items]]` syntax) is not, since TOML has no syntax for that
    * editing a leaf nested inside an inline table (`x = { a = 1 }`) below
      the top level — the inline table itself can be replaced, deleted, or
      have a new key/array-element appended (all via a single self-contained
      line rewrite), but reaching into `x.a` specifically is not
  """

  @behaviour OrcaHub.ConfigFile.Format

  alias OrcaHub.ConfigFile

  @array_header_rx ~r/^\[\[(.+)\]\]\s*(?:#.*)?$/
  @table_header_rx ~r/^\[(.+)\]\s*(?:#.*)?$/
  @kv_rx ~r/^(\s*)((?:[A-Za-z0-9_-]+|"[^"]*"|'[^']*')(?:\s*\.\s*(?:[A-Za-z0-9_-]+|"[^"]*"|'[^']*'))*)\s*=\s*(.*)$/
  @key_segment_rx ~r/"([^"]*)"|'([^']*)'|([A-Za-z0-9_-]+)/
  @bare_key_rx ~r/^[A-Za-z0-9_-]+$/

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
    case Toml.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, {:invalid_toml, msg}} -> {:error, msg}
      {:error, reason} when is_binary(reason) -> {:error, reason}
      {:error, reason} -> {:error, inspect(reason)}
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

  # Deleting an array index shifts later elements down rather than leaving a
  # hole, so the path itself may still resolve (to what used to be the next
  # element) — the correct check is that the parent array's length dropped
  # by exactly one, not that the path is now empty.
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

  defp to_tree(map, order, path) when is_map(map) and not is_struct(map) do
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
  defp normalize_leaf(%Date{} = d), do: {Date.to_iso8601(d), :string}
  defp normalize_leaf(%DateTime{} = d), do: {DateTime.to_iso8601(d), :string}
  defp normalize_leaf(%NaiveDateTime{} = d), do: {NaiveDateTime.to_iso8601(d), :string}
  defp normalize_leaf(%Time{} = t), do: {Time.to_iso8601(t), :string}
  defp normalize_leaf(v), do: {inspect(v), :string}

  # -------------------------------------------------------------------
  # Line scan — builds, in one pass, everything both `parse/1` (`order`)
  # and `apply_op/2` (`kv_lines`, `header_map`, `headers`, `array_bases`)
  # need. `current` tracks the resolved path (mixing string keys and
  # integer array-of-tables indices, exactly like a `ConfigFile.path`) of
  # whichever table/array-table header was most recently seen — TOML table
  # headers are absolute from the document root, EXCEPT that a dotted
  # header passing through an array-of-tables name implicitly refers to
  # that array's most-recently-opened element, which `array_counters`
  # (path -> current index) resolves.
  # -------------------------------------------------------------------

  defp scan(raw) do
    lines = String.split(raw, "\n")

    {state, _bracket} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({initial_scan_state(), {0, nil, false}}, fn {line, idx}, {state, bracket} ->
        {depth, _quote, _escape} = bracket
        state = if depth == 0, do: scan_line(line, idx, state), else: state
        {state, scan_bracket_state(line, bracket)}
      end)

    %{state | headers: Enum.reverse(state.headers)}
  end

  defp initial_scan_state do
    %{
      order: %{},
      kv_lines: %{},
      header_map: %{},
      headers: [],
      array_bases: %{},
      array_counters: %{},
      current: []
    }
  end

  defp scan_line(line, idx, state) do
    trimmed = String.trim(line)

    cond do
      trimmed == "" or String.starts_with?(trimmed, "#") ->
        state

      match = Regex.run(@array_header_rx, trimmed) ->
        scan_array_header(match, idx, state)

      match = Regex.run(@table_header_rx, trimmed) ->
        scan_table_header(match, idx, state)

      match = Regex.run(@kv_rx, line) ->
        scan_kv(match, idx, state)

      true ->
        state
    end
  end

  defp scan_table_header([_, header_text], idx, state) do
    segments = split_key_path(header_text)
    resolved_path = resolve_table_path(segments, state.array_counters)

    state
    |> register_path_chain(resolved_path)
    |> Map.put(:current, resolved_path)
    |> Map.update!(:header_map, &Map.put(&1, resolved_path, {idx, :table}))
    |> Map.update!(:headers, &[{idx, resolved_path} | &1])
  end

  defp scan_array_header([_, header_text], idx, state) do
    segments = split_key_path(header_text)
    base_path = resolve_array_base_path(segments, state.array_counters)
    next_index = Map.get(state.array_counters, base_path, -1) + 1
    resolved_path = base_path ++ [next_index]

    state
    |> register_path_chain(base_path)
    |> Map.update!(:array_counters, &Map.put(&1, base_path, next_index))
    |> Map.put(:current, resolved_path)
    |> Map.update!(:header_map, &Map.put(&1, resolved_path, {idx, :array_table}))
    |> Map.update!(:headers, &[{idx, resolved_path} | &1])
    |> Map.update!(:array_bases, fn bases ->
      Map.update(bases, base_path, [idx], &(&1 ++ [idx]))
    end)
  end

  defp scan_kv([_, _indent, key_text, _rest], idx, state) do
    segments = split_key_path(key_text)
    full_path = state.current ++ segments

    state
    |> register_path_chain(full_path)
    |> Map.update!(:kv_lines, &Map.put(&1, full_path, idx))
  end

  # Resolves a header's dotted segments to a full `ConfigFile.path`,
  # splicing in the current index of any ancestor segment that's a known
  # array-of-tables name (see moduledoc). `resolve_table_path` also checks
  # the final segment (a plain table can itself be inside the most-recent
  # element of an array named by its own last segment); `resolve_array_base_path`
  # never indexes its own final segment, since that's the array whose next
  # occurrence we're about to define.
  defp resolve_table_path(segments, array_counters),
    do: resolve_prefix_path(segments, array_counters)

  defp resolve_array_base_path(segments, array_counters) do
    {ancestors, last} = Enum.split(segments, -1)
    resolve_prefix_path(ancestors, array_counters) ++ last
  end

  defp resolve_prefix_path(segments, array_counters) do
    {resolved, _prefix} =
      Enum.reduce(segments, {[], []}, fn seg, {resolved, str_prefix} ->
        str_prefix = str_prefix ++ [seg]

        resolved =
          case Map.get(array_counters, str_prefix) do
            nil -> resolved ++ [seg]
            idx -> resolved ++ [seg, idx]
          end

        {resolved, str_prefix}
      end)

    resolved
  end

  # Registers every segment of `resolved_path` as a child of its immediate
  # parent in `order` (skipping integer/array-index segments, which don't
  # need ordering — list order already survives via the decoder). Safe to
  # call redundantly with paths whose prefix was already registered
  # (idempotent — `append_child` no-ops on an already-known child).
  defp register_path_chain(state, resolved_path) do
    {order, _parent} =
      Enum.reduce(resolved_path, {state.order, []}, fn seg, {order, parent} ->
        order = if is_binary(seg), do: append_child(order, parent, seg), else: order
        {order, parent ++ [seg]}
      end)

    %{state | order: order}
  end

  defp append_child(order, parent_path, child_key) do
    Map.update(order, parent_path, [child_key], fn existing ->
      if child_key in existing, do: existing, else: existing ++ [child_key]
    end)
  end

  defp split_key_path(text) do
    Regex.scan(@key_segment_rx, text)
    |> Enum.map(fn [_whole, dq, sq, bare] ->
      cond do
        dq != "" -> dq
        sq != "" -> sq
        true -> bare
      end
    end)
  end

  # -------------------------------------------------------------------
  # apply_op/2 dispatch
  # -------------------------------------------------------------------

  defp run_op(raw, scanned, tree, {:set, path, value}) do
    case ConfigFile.get_node(tree, path) do
      nil -> {:error, {:not_found, List.last(path)}}
      %{kind: :leaf} -> set_leaf(raw, scanned, path, value)
      _ -> {:error, :unsupported_structure}
    end
  end

  defp run_op(raw, scanned, tree, {:delete, path}) do
    case ConfigFile.get_node(tree, path) do
      nil -> {:error, {:not_found, List.last(path)}}
      _ -> delete_node(raw, scanned, path)
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
          add_child(raw, scanned, parent_path, key, value, :object)
        end

      %{kind: :array} when is_nil(key) ->
        add_child(raw, scanned, parent_path, nil, value, :array)

      _ ->
        {:error, :unsupported_structure}
    end
  end

  # -------------------------------------------------------------------
  # :set — either the whole value on a `key = value` line, or one element
  # of a single-line scalar array.
  # -------------------------------------------------------------------

  defp set_leaf(raw, scanned, path, value) do
    parent = drop_last(path)
    last = List.last(path)

    cond do
      Map.has_key?(scanned.kv_lines, path) ->
        replace_kv_line(raw, Map.fetch!(scanned.kv_lines, path), value)

      is_integer(last) and Map.has_key?(scanned.kv_lines, parent) ->
        set_array_element(raw, Map.fetch!(scanned.kv_lines, parent), last, value)

      true ->
        {:error, :unsupported_structure}
    end
  end

  defp replace_kv_line(raw, line_idx, value) do
    with {:ok, literal} <- serialize_toml_value(value) do
      rewrite_line(raw, line_idx, fn _rest -> literal end)
    end
  end

  defp set_array_element(raw, line_idx, index, value) do
    with {:ok, literal} <- serialize_toml_value(value) do
      rewrite_array_line(raw, line_idx, fn elements ->
        if index >= 0 and index < length(elements) do
          {:ok, List.replace_at(elements, index, literal)}
        else
          {:error, {:not_found, index}}
        end
      end)
    end
  end

  # -------------------------------------------------------------------
  # :delete — a whole `key = value` line, a table/array-table header's
  # full range, every occurrence of an array-of-tables, or one element of
  # a single-line scalar array.
  # -------------------------------------------------------------------

  defp delete_node(raw, scanned, path) do
    parent = drop_last(path)
    last = List.last(path)

    cond do
      header = Map.get(scanned.header_map, path) ->
        {header_idx, _kind} = header
        delete_full_range(raw, scanned, path, header_idx)

      is_integer(last) and Map.has_key?(scanned.array_bases, parent) ->
        {:error, :unsupported_structure}

      is_integer(last) and Map.has_key?(scanned.kv_lines, parent) ->
        delete_array_element(raw, Map.fetch!(scanned.kv_lines, parent), last)

      Map.has_key?(scanned.array_bases, path) ->
        delete_array_bases(raw, scanned, path)

      Map.has_key?(scanned.kv_lines, path) ->
        delete_single_line(raw, Map.fetch!(scanned.kv_lines, path))

      true ->
        {:error, :unsupported_structure}
    end
  end

  defp delete_single_line(raw, line_idx) do
    lines = String.split(raw, "\n")
    {:ok, lines |> remove_line_ranges([{line_idx, line_idx + 1}]) |> Enum.join("\n")}
  end

  defp delete_full_range(raw, scanned, path, header_idx) do
    lines = String.split(raw, "\n")
    end_idx = full_range_end(scanned.headers, header_idx, path, length(lines))
    {:ok, lines |> remove_line_ranges([{header_idx, end_idx}]) |> Enum.join("\n")}
  end

  defp delete_array_bases(raw, scanned, base_path) do
    lines = String.split(raw, "\n")
    lines_count = length(lines)

    ranges =
      scanned.array_bases
      |> Map.fetch!(base_path)
      |> Enum.with_index()
      |> Enum.map(fn {header_idx, occurrence_idx} ->
        {header_idx,
         full_range_end(scanned.headers, header_idx, base_path ++ [occurrence_idx], lines_count)}
      end)

    {:ok, lines |> remove_line_ranges(ranges) |> Enum.join("\n")}
  end

  defp delete_array_element(raw, line_idx, index) do
    rewrite_array_line(raw, line_idx, fn elements ->
      if index >= 0 and index < length(elements) do
        {:ok, List.delete_at(elements, index)}
      else
        {:error, {:not_found, index}}
      end
    end)
  end

  defp remove_line_ranges(lines, ranges) do
    to_remove =
      ranges |> Enum.flat_map(fn {s, e} -> Enum.to_list(s..(e - 1)//1) end) |> MapSet.new()

    lines
    |> Enum.with_index()
    |> Enum.reject(fn {_line, idx} -> idx in to_remove end)
    |> Enum.map(&elem(&1, 0))
  end

  # A table/array-table header's content ends at the next header line whose
  # resolved path is NOT a descendant of `path` — this intentionally
  # includes nested sub-tables (`[alpha.beta]` after `[alpha]`) in "alpha"'s
  # range, since deleting a table should take its nested tables with it.
  defp full_range_end(headers, header_idx, path, lines_count) do
    headers
    |> Enum.find(fn {idx, other_path} ->
      idx > header_idx and not descendant?(path, other_path)
    end)
    |> case do
      {idx, _path} -> idx
      nil -> lines_count
    end
  end

  # A header's OWN direct content (for insertion points) ends at the very
  # next header line, full stop — nested sub-tables get their own region.
  defp own_range_end(headers, header_idx, lines_count) do
    headers
    |> Enum.find(fn {idx, _path} -> idx > header_idx end)
    |> case do
      {idx, _path} -> idx
      nil -> lines_count
    end
  end

  defp root_own_range_end(headers, lines_count) do
    case headers do
      [{idx, _path} | _] -> idx
      [] -> lines_count
    end
  end

  defp descendant?(parent, path), do: path != parent and Enum.take(path, length(parent)) == parent

  # -------------------------------------------------------------------
  # :add — append a `key = value` line to a table's own range (creating it
  # at EOF for the root table), or splice a new element/pair into a
  # self-contained single-line array or inline table.
  # -------------------------------------------------------------------

  defp add_child(raw, scanned, [], key, value, _node_kind) do
    with {:ok, literal} <- serialize_toml_value(value) do
      lines = String.split(raw, "\n")
      insert_idx = root_own_range_end(scanned.headers, length(lines))
      new_line = "#{encode_toml_key(key)} = #{literal}"
      {:ok, lines |> List.insert_at(insert_idx, new_line) |> Enum.join("\n")}
    end
  end

  defp add_child(raw, scanned, parent_path, key, value, node_kind) do
    case Map.get(scanned.header_map, parent_path) do
      {header_idx, _kind} ->
        add_key_to_table(raw, scanned, header_idx, key, value)

      nil ->
        add_child_fallback(raw, scanned, parent_path, key, value, node_kind)
    end
  end

  defp add_key_to_table(raw, scanned, header_idx, key, value) do
    with {:ok, literal} <- serialize_toml_value(value) do
      lines = String.split(raw, "\n")
      insert_idx = own_range_end(scanned.headers, header_idx, length(lines))
      new_line = "#{encode_toml_key(key)} = #{literal}"
      {:ok, lines |> List.insert_at(insert_idx, new_line) |> Enum.join("\n")}
    end
  end

  defp add_child_fallback(raw, scanned, parent_path, nil, value, :array) do
    cond do
      Map.has_key?(scanned.array_bases, parent_path) ->
        {:error, :unsupported_structure}

      Map.has_key?(scanned.kv_lines, parent_path) ->
        with {:ok, literal} <- serialize_toml_value(value) do
          rewrite_array_line(raw, Map.fetch!(scanned.kv_lines, parent_path), fn elements ->
            {:ok, elements ++ [literal]}
          end)
        end

      true ->
        {:error, :unsupported_structure}
    end
  end

  defp add_child_fallback(raw, scanned, parent_path, key, value, _node_kind)
       when is_binary(key) do
    case Map.get(scanned.kv_lines, parent_path) do
      nil ->
        {:error, :unsupported_structure}

      line_idx ->
        with {:ok, literal} <- serialize_toml_value(value) do
          new_pair = "#{encode_toml_key(key)} = #{literal}"
          rewrite_inline_table_line(raw, line_idx, fn pairs -> {:ok, pairs ++ [new_pair]} end)
        end
    end
  end

  # -------------------------------------------------------------------
  # Single-line rewrite helpers — every mutation of a `key = value` line
  # goes through `@kv_rx` again on the CURRENT text (not the scan's cached
  # match), splits off any trailing comment with a quote-aware scan, and
  # reassembles indent + key text (preserving exact original spelling and
  # quoting) + new value + comment untouched.
  # -------------------------------------------------------------------

  defp rewrite_line(raw, line_idx, value_fun) do
    lines = String.split(raw, "\n")
    line = Enum.at(lines, line_idx)

    case Regex.run(@kv_rx, line) do
      [_, indent, key_text, rest] ->
        {_value_text, comment} = split_trailing_comment(rest)
        new_line = indent <> key_text <> " = " <> value_fun.(rest) <> comment_suffix(comment)
        {:ok, lines |> List.replace_at(line_idx, new_line) |> Enum.join("\n")}

      nil ->
        {:error, :unsupported_structure}
    end
  end

  defp rewrite_array_line(raw, line_idx, elements_fun) do
    rewrite_delimited_line(raw, line_idx, "[", "]", elements_fun, fn new_elements ->
      "[" <> Enum.join(new_elements, ", ") <> "]"
    end)
  end

  defp rewrite_inline_table_line(raw, line_idx, pairs_fun) do
    rewrite_delimited_line(raw, line_idx, "{", "}", pairs_fun, fn new_pairs ->
      "{ " <> Enum.join(new_pairs, ", ") <> " }"
    end)
  end

  defp rewrite_delimited_line(raw, line_idx, open, close, elements_fun, render_fun) do
    lines = String.split(raw, "\n")
    line = Enum.at(lines, line_idx)

    with [_, indent, key_text, rest] <- Regex.run(@kv_rx, line),
         {value_text, comment} <- split_trailing_comment(rest),
         trimmed <- String.trim(value_text),
         true <-
           String.starts_with?(trimmed, open) and String.ends_with?(trimmed, close) and
             self_contained?(trimmed),
         inner <- String.slice(trimmed, 1..-2//1),
         elements <- split_top_level(inner, ","),
         {:ok, new_elements} <- elements_fun.(elements) do
      new_line =
        indent <> key_text <> " = " <> render_fun.(new_elements) <> comment_suffix(comment)

      {:ok, lines |> List.replace_at(line_idx, new_line) |> Enum.join("\n")}
    else
      {:error, {:not_found, idx}} -> {:error, {:not_found, idx}}
      _ -> {:error, :unsupported_structure}
    end
  end

  # -------------------------------------------------------------------
  # Value / string / key serialization
  # -------------------------------------------------------------------

  defp serialize_toml_value(nil), do: {:error, :unsupported_value}
  defp serialize_toml_value(v) when is_boolean(v), do: {:ok, to_string(v)}
  defp serialize_toml_value(v) when is_integer(v), do: {:ok, Integer.to_string(v)}
  defp serialize_toml_value(v) when is_float(v), do: {:ok, Float.to_string(v)}
  defp serialize_toml_value(v) when is_binary(v), do: {:ok, encode_toml_string(v)}
  defp serialize_toml_value(_v), do: {:error, :unsupported_value}

  defp encode_toml_string(v) do
    escaped =
      v
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\t", "\\t")
      |> String.replace("\r", "\\r")

    "\"" <> escaped <> "\""
  end

  defp encode_toml_key(key) do
    if Regex.match?(@bare_key_rx, key), do: key, else: encode_toml_string(key)
  end

  # -------------------------------------------------------------------
  # Small character-level scanners — quote/bracket-aware so a `#` or `,`
  # inside a quoted string is never mistaken for a comment or separator.
  # -------------------------------------------------------------------

  defp split_trailing_comment(text), do: scan_for_comment(text, 0, false, nil)

  defp scan_for_comment(text, idx, in_quote, quote_char) do
    len = String.length(text)

    if idx >= len do
      {text, nil}
    else
      ch = String.at(text, idx)

      cond do
        in_quote and quote_char == "\"" and ch == "\\" ->
          scan_for_comment(text, idx + 2, in_quote, quote_char)

        in_quote and ch == quote_char ->
          scan_for_comment(text, idx + 1, false, nil)

        in_quote ->
          scan_for_comment(text, idx + 1, in_quote, quote_char)

        ch in ["\"", "'"] ->
          scan_for_comment(text, idx + 1, true, ch)

        ch == "#" ->
          {String.slice(text, 0, idx), String.slice(text, idx, len - idx)}

        true ->
          scan_for_comment(text, idx + 1, in_quote, quote_char)
      end
    end
  end

  defp comment_suffix(nil), do: ""
  defp comment_suffix(comment), do: "  " <> comment

  defp self_contained?(text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while({0, nil, false}, &bracket_step/2)
    |> case do
      {0, nil, false} -> true
      _ -> false
    end
  end

  defp bracket_step(ch, {depth, quote, escape}) do
    cond do
      escape -> {:cont, {depth, quote, false}}
      quote == "\"" and ch == "\\" -> {:cont, {depth, quote, true}}
      quote != nil and ch == quote -> {:cont, {depth, nil, false}}
      quote != nil -> {:cont, {depth, quote, false}}
      ch in ["\"", "'"] -> {:cont, {depth, ch, false}}
      ch in ["[", "{"] -> {:cont, {depth + 1, quote, false}}
      ch in ["]", "}"] and depth == 0 -> {:halt, :invalid}
      ch in ["]", "}"] -> {:cont, {depth - 1, quote, false}}
      true -> {:cont, {depth, quote, false}}
    end
  end

  defp scan_bracket_state(line, {depth, quote, escape}) do
    line
    |> String.graphemes()
    |> Enum.reduce({depth, quote, escape}, fn ch, {depth, quote, escape} ->
      cond do
        escape -> {depth, quote, false}
        quote == "\"" and ch == "\\" -> {depth, quote, true}
        quote != nil and ch == quote -> {depth, nil, false}
        quote != nil -> {depth, quote, false}
        ch in ["\"", "'"] -> {depth, ch, false}
        ch in ["[", "{"] -> {depth + 1, quote, false}
        ch in ["]", "}"] -> {max(depth - 1, 0), quote, false}
        true -> {depth, quote, false}
      end
    end)
  end

  defp split_top_level(text, sep) do
    {parts, current, _state} =
      text
      |> String.graphemes()
      |> Enum.reduce(
        {[], "", %{depth: 0, quote: nil, escape: false}},
        &split_top_level_step(&1, &2, sep)
      )

    trimmed_last = String.trim(current)
    result = Enum.reverse(parts)
    if trimmed_last == "", do: result, else: result ++ [trimmed_last]
  end

  defp split_top_level_step(ch, {parts, current, state}, sep) do
    cond do
      state.escape ->
        {parts, current <> ch, %{state | escape: false}}

      state.quote == "\"" and ch == "\\" ->
        {parts, current <> ch, %{state | escape: true}}

      state.quote != nil and ch == state.quote ->
        {parts, current <> ch, %{state | quote: nil}}

      state.quote != nil ->
        {parts, current <> ch, state}

      ch in ["\"", "'"] ->
        {parts, current <> ch, %{state | quote: ch}}

      ch in ["[", "{"] ->
        {parts, current <> ch, %{state | depth: state.depth + 1}}

      ch in ["]", "}"] ->
        {parts, current <> ch, %{state | depth: max(state.depth - 1, 0)}}

      ch == sep and state.depth == 0 ->
        {[String.trim(current) | parts], "", state}

      true ->
        {parts, current <> ch, state}
    end
  end

  defp drop_last(list), do: Enum.drop(list, -1)
end
