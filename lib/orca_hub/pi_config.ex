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

  defp notify_change do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, @topic, {:pi_config_updated})
  end
end
