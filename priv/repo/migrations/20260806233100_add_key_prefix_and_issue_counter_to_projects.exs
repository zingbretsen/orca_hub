defmodule OrcaHub.Repo.Migrations.AddKeyPrefixAndIssueCounterToProjects do
  @moduledoc """
  Adds `projects.key_prefix`/`issue_counter` (issues_spec.md §3.2) and
  deterministically backfills `key_prefix` for every existing project.

  Backfill algorithm (§3.2.3): derive a candidate per project (strip
  non-alnum, uppercase, truncate to 10 chars), process in a stable order
  (`inserted_at` ASC, `id` ASC as a tiebreaker so the order is fully
  deterministic even for rows inserted in the same instant) so a re-run
  against a fresh copy of the same data always produces the same output.
  First project to claim a candidate wins it unmodified; every later
  project whose candidate collides gets the shortest available numeric
  suffix (`ORCA`, then `ORCA2`, `ORCA3`, ...), re-truncating the base so
  the suffixed key still fits the 10-char cap.

  Two edge cases the spec's prose didn't spell out, handled here:
    - A name that derives to an empty string, or one that doesn't start
      with a letter after stripping (e.g. a project literally named
      "123"), falls back to the literal candidate "PROJ" (then dedups
      via the same numeric-suffix mechanism as any other collision).
    - A derived candidate shorter than 2 chars is right-padded with "X"
      to satisfy the 2-10 char length rule.

  Idempotent/re-runnable: only ever sets `key_prefix` where it is
  currently NULL, so running this migration twice (or restoring from a
  backup mid-way through a partial run) never reassigns an
  already-backfilled project's prefix.
  """

  use Ecto.Migration

  def up do
    alter table(:projects) do
      add :issue_counter, :integer, null: false, default: 0
      add :key_prefix, :string
    end

    flush()

    backfill_key_prefixes()

    create unique_index(:projects, [:key_prefix])
  end

  def down do
    drop_if_exists unique_index(:projects, [:key_prefix])

    alter table(:projects) do
      remove :key_prefix
      remove :issue_counter
    end
  end

  defp backfill_key_prefixes do
    repo = repo()

    %{rows: rows} =
      repo.query!("SELECT id, name, key_prefix FROM projects ORDER BY inserted_at ASC, id ASC")

    already_used =
      rows
      |> Enum.map(fn [_id, _name, key_prefix] -> key_prefix end)
      |> Enum.filter(& &1)
      |> MapSet.new()

    {_used, updates} =
      Enum.reduce(rows, {already_used, []}, fn
        [_id, _name, key_prefix], {used, updates} when is_binary(key_prefix) ->
          {used, updates}

        [id, name, nil], {used, updates} ->
          candidate = derive_candidate(name)
          final = uniquify(candidate, used)
          {MapSet.put(used, final), [{id, final} | updates]}
      end)

    Enum.each(updates, fn {id, key_prefix} ->
      repo.query!("UPDATE projects SET key_prefix = $1 WHERE id = $2", [key_prefix, id])
    end)
  end

  defp derive_candidate(name) do
    base =
      (name || "")
      |> String.upcase()
      |> String.replace(~r/[^A-Z0-9]/, "")
      |> String.slice(0, 10)

    cond do
      base == "" -> "PROJ"
      not String.match?(String.at(base, 0), ~r/[A-Z]/) -> "PROJ"
      String.length(base) < 2 -> String.pad_trailing(base, 2, "X")
      true -> base
    end
  end

  defp uniquify(candidate, used) do
    if MapSet.member?(used, candidate) do
      find_unique_suffix(candidate, used, 2)
    else
      candidate
    end
  end

  defp find_unique_suffix(base, used, n) do
    suffix = Integer.to_string(n)
    max_base_len = 10 - String.length(suffix)
    candidate = String.slice(base, 0, max_base_len) <> suffix

    if MapSet.member?(used, candidate) do
      find_unique_suffix(base, used, n + 1)
    else
      candidate
    end
  end
end
