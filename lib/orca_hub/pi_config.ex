defmodule OrcaHub.PiConfig do
  @moduledoc """
  Context for hub-managed pi global config — custom providers/models
  (`models.json`), `settings.json` keys, extensions, prompt templates, and
  themes (Phase 1 of pi config federation; see `OrcaHub.PiConfigSync` for
  how these rows get materialized into each node's `~/.pi/agent/`).

  Same shape as `OrcaHub.Skills`: the hub DB is the source of truth, and
  every successful create/update/delete broadcasts `{:pi_config_updated}` on
  PubSub topic `"pi_config"`. `Phoenix.PubSub` auto-distributes that to
  agent nodes via `:pg`, so every node's `OrcaHub.PiConfigSync` re-syncs
  without any node-specific plumbing.
  """

  import Ecto.Query
  alias OrcaHub.{PiConfig.Entry, Repo}

  @topic "pi_config"

  @doc "The PubSub topic mutations broadcast on."
  def topic, do: @topic

  def list_entries do
    Repo.all(from e in Entry, order_by: [asc: e.kind, asc: e.name])
  end

  def list_entries(kind) when is_binary(kind) do
    Repo.all(from e in Entry, where: e.kind == ^kind, order_by: [asc: e.name])
  end

  @doc "Enabled entries across every kind, in the shape `OrcaHub.PiConfigSync` consumes."
  def list_enabled_entries do
    Repo.all(from e in Entry, where: e.enabled == true, order_by: [asc: e.kind, asc: e.name])
  end

  def list_enabled_entries(kind) when is_binary(kind) do
    Repo.all(
      from e in Entry,
        where: e.enabled == true and e.kind == ^kind,
        order_by: [asc: e.name]
    )
  end

  def get_entry!(id), do: Repo.get!(Entry, id)
  def get_entry(id), do: Repo.get(Entry, id)
  def get_entry_by_kind_and_name(kind, name), do: Repo.get_by(Entry, kind: kind, name: name)

  def create_entry(attrs) do
    result =
      %Entry{}
      |> Entry.changeset(attrs)
      |> Repo.insert()

    with {:ok, _entry} <- result, do: notify_change()

    result
  end

  def update_entry(%Entry{} = entry, attrs) do
    result =
      entry
      |> Entry.changeset(attrs)
      |> Repo.update()

    with {:ok, _entry} <- result, do: notify_change()

    result
  end

  def delete_entry(%Entry{} = entry) do
    result = Repo.delete(entry)

    with {:ok, _entry} <- result, do: notify_change()

    result
  end

  def change_entry(%Entry{} = entry, attrs \\ %{}), do: Entry.changeset(entry, attrs)

  @doc """
  Every `provider` entry that has opted into dynamic model resolution —
  `OrcaHub.PiModelSync`'s work list. Disabled rows are included on purpose:
  a disabled provider isn't materialized onto any node, so refreshing it is
  harmless, and it means re-enabling one doesn't hand pi a months-stale list.
  """
  def list_model_managed_entries do
    Repo.all(
      from e in Entry,
        where: e.kind == "provider" and not is_nil(e.models_from),
        order_by: [asc: e.name]
    )
  end

  @doc """
  Records the outcome of a model-resolution pass WITHOUT broadcasting
  `{:pi_config_updated}`.

  Deliberately broadcast-free: a refresh that resolved to the same model set
  (the overwhelmingly common case — the gateway's list changes via a git
  edit of its `UPSTREAMS` env, not at runtime) must not fan a sync out to
  every node, because an actual `models.json` write evicts every idle warm
  pi port cluster-wide (`PiConfigSync.sync/1`). Only `spec` changes go
  through `update_entry/2`.

  Accepts only the three bookkeeping columns; `spec` is never touched here.
  """
  def record_models_refresh(%Entry{} = entry, attrs) do
    attrs = Map.take(normalize_keys(attrs), [:models_refreshed_at, :models_refresh_error])

    entry
    |> Ecto.Changeset.change(attrs)
    |> Repo.update()
  end

  defp normalize_keys(attrs) do
    Map.new(attrs, fn
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
      {k, v} -> {k, v}
    end)
  end

  defp notify_change do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, @topic, {:pi_config_updated})
  end
end
