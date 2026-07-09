defmodule OrcaHub.ConfigFile.Json do
  @moduledoc """
  JSON adapter for `OrcaHub.ConfigFile`. Decodes with
  `objects: :ordered_objects` (`Jason.OrderedObject`) so key order survives
  a decode/mutate/re-encode round trip untouched, including for keys the
  edit never touches. `apply_op/2` re-decodes, applies the op to the
  ordered structure, and re-encodes with `pretty: true` — safe for JSON
  specifically because there's no comment/whitespace to lose, unlike a
  TOML/YAML adapter which must do a surgical text edit instead (see
  `OrcaHub.ConfigFile.Format`'s moduledoc).
  """

  @behaviour OrcaHub.ConfigFile.Format

  alias Jason.OrderedObject

  @impl true
  def parse(raw) do
    with {:ok, decoded} <- decode(raw) do
      {:ok, to_tree(decoded, [])}
    end
  end

  @impl true
  def apply_op(raw, op) do
    with {:ok, decoded} <- decode(raw),
         {:ok, updated} <- run_op(decoded, op) do
      {:ok, Jason.encode!(updated, pretty: true) <> "\n"}
    end
  end

  defp decode(raw) do
    case Jason.decode(raw, objects: :ordered_objects) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, %Jason.DecodeError{} = error} -> {:error, Exception.message(error)}
    end
  end

  # -------------------------------------------------------------------
  # Decoded structure -> normalized tree
  # -------------------------------------------------------------------

  defp to_tree(%OrderedObject{values: values}, path) do
    entries = Enum.map(values, fn {key, value} -> {key, to_tree(value, path ++ [key])} end)
    %{kind: :object, path: path, entries: entries}
  end

  defp to_tree(list, path) when is_list(list) do
    items = list |> Enum.with_index() |> Enum.map(fn {v, i} -> to_tree(v, path ++ [i]) end)
    %{kind: :array, path: path, items: items}
  end

  defp to_tree(value, path) do
    %{kind: :leaf, path: path, value: value, value_type: value_type(value)}
  end

  defp value_type(v) when is_binary(v), do: :string
  defp value_type(v) when is_integer(v), do: :integer
  defp value_type(v) when is_float(v), do: :float
  defp value_type(v) when is_boolean(v), do: :boolean
  defp value_type(nil), do: :null

  # -------------------------------------------------------------------
  # Ops, applied directly to the decoded (pre-normalization) structure
  # -------------------------------------------------------------------

  defp run_op(decoded, {:set, path, value}), do: set_at(decoded, path, value)
  defp run_op(decoded, {:delete, path}), do: delete_at(decoded, path)
  defp run_op(decoded, {:add, path, key, value}), do: add_at(decoded, path, key, value)

  defp set_at(container, path, value) do
    case split_last(path) do
      {:error, reason} ->
        {:error, reason}

      {parent_path, last} ->
        update_container_at(container, parent_path, &set_child(&1, last, value))
    end
  end

  defp delete_at(container, path) do
    case split_last(path) do
      {:error, reason} -> {:error, reason}
      {parent_path, last} -> update_container_at(container, parent_path, &delete_child(&1, last))
    end
  end

  defp add_at(container, parent_path, key, value) do
    update_container_at(container, parent_path, &add_child(&1, key, value))
  end

  defp split_last([]), do: {:error, :invalid_path}
  defp split_last(path), do: path |> Enum.split(-1) |> then(fn {p, [last]} -> {p, last} end)

  # Walks down to the container at `path`, applies `fun` to it, and
  # rebuilds the structure back up with the result spliced in.
  defp update_container_at(container, [], fun), do: fun.(container)

  defp update_container_at(%OrderedObject{values: values}, [key | rest], fun)
       when is_binary(key) do
    case List.keyfind(values, key, 0) do
      {^key, child} ->
        with {:ok, new_child} <- update_container_at(child, rest, fun) do
          {:ok, %OrderedObject{values: List.keyreplace(values, key, 0, {key, new_child})}}
        end

      nil ->
        {:error, {:not_found, key}}
    end
  end

  defp update_container_at(list, [index | rest], fun) when is_list(list) and is_integer(index) do
    case Enum.at(list, index, :__config_file_missing__) do
      :__config_file_missing__ ->
        {:error, {:not_found, index}}

      child ->
        with {:ok, new_child} <- update_container_at(child, rest, fun) do
          {:ok, List.replace_at(list, index, new_child)}
        end
    end
  end

  defp update_container_at(_container, _path, _fun), do: {:error, :invalid_path}

  defp set_child(%OrderedObject{values: values}, key, value) when is_binary(key) do
    if List.keymember?(values, key, 0) do
      {:ok, %OrderedObject{values: List.keyreplace(values, key, 0, {key, value})}}
    else
      {:error, {:not_found, key}}
    end
  end

  defp set_child(list, index, value) when is_list(list) and is_integer(index) do
    if index >= 0 and index < length(list) do
      {:ok, List.replace_at(list, index, value)}
    else
      {:error, {:not_found, index}}
    end
  end

  defp set_child(_container, _key_or_index, _value), do: {:error, :invalid_path}

  defp delete_child(%OrderedObject{values: values}, key) when is_binary(key) do
    if List.keymember?(values, key, 0) do
      {:ok, %OrderedObject{values: List.keydelete(values, key, 0)}}
    else
      {:error, {:not_found, key}}
    end
  end

  defp delete_child(list, index) when is_list(list) and is_integer(index) do
    if index >= 0 and index < length(list) do
      {:ok, List.delete_at(list, index)}
    else
      {:error, {:not_found, index}}
    end
  end

  defp delete_child(_container, _key_or_index), do: {:error, :invalid_path}

  defp add_child(%OrderedObject{values: values}, key, value) when is_binary(key) do
    if List.keymember?(values, key, 0) do
      {:error, :already_exists}
    else
      {:ok, %OrderedObject{values: values ++ [{key, value}]}}
    end
  end

  defp add_child(list, nil, value) when is_list(list), do: {:ok, list ++ [value]}
  defp add_child(_container, _key, _value), do: {:error, :invalid_path}
end
