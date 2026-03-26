defmodule OrcaHub.Settings do
  @moduledoc """
  Context for application settings stored as key-value pairs.
  """

  import Ecto.Query
  alias OrcaHub.Repo
  alias OrcaHub.Settings.Setting

  @doc """
  Get a setting value by key. Returns nil if not found.
  """
  def get(key) when is_binary(key) do
    case Repo.get(Setting, key) do
      nil -> nil
      setting -> setting.value
    end
  end

  @doc """
  Get a setting value by key, with a default fallback.
  """
  def get(key, default) when is_binary(key) do
    get(key) || default
  end

  @doc """
  Set a setting value. Creates or updates the key.
  """
  def put(key, value) when is_binary(key) do
    case Repo.get(Setting, key) do
      nil ->
        %Setting{}
        |> Setting.changeset(%{key: key, value: value})
        |> Repo.insert()

      setting ->
        setting
        |> Setting.changeset(%{value: value})
        |> Repo.update()
    end
  end

  @doc """
  Delete a setting by key.
  """
  def delete(key) when is_binary(key) do
    case Repo.get(Setting, key) do
      nil -> :ok
      setting -> Repo.delete(setting) |> elem(0)
    end
  end

  @doc """
  Get all settings as a map of key => value.
  """
  def all do
    Setting
    |> Repo.all()
    |> Map.new(fn s -> {s.key, s.value} end)
  end

  @doc """
  Get all settings matching a key prefix (e.g., "todoist_" for all todoist settings).
  """
  def get_by_prefix(prefix) when is_binary(prefix) do
    from(s in Setting, where: like(s.key, ^"#{prefix}%"))
    |> Repo.all()
    |> Map.new(fn s -> {s.key, s.value} end)
  end
end
