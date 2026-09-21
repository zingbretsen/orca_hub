defmodule OrcaHub.DrainStatus do
  @moduledoc """
  "Is THIS instance safe to restart right now?" — the data behind
  `GET /api/drain` (see `OrcaHubWeb.Endpoint`).

  The deploy script (`~/homelab/scripts/deploy-orca-hub.sh`) restarts the
  local/mini/gb10 systemd agents. A restart kills every port-backed session
  and every detached job watcher this node owns, so before it fires the
  script asks the host itself whether it's mid-flight.

  Two kinds of in-flight work count, both scoped to `runner_node == node()`:

    * sessions in an ACTIVE status (`running`, `waiting`, `compacting`) —
      `waiting` is an unanswered AskUserQuestion and `compacting` a context
      compaction, both mid-turn states a restart would drop;
    * jobs in `OrcaHub.Jobs.Job.nonterminal_statuses/0` (`running` /
      `verifying`). A job's OS process is DETACHED and survives a restart —
      only its watcher dies, and `OrcaHub.JobResumer` re-attaches on boot —
      so this is a softer signal than an active session. It still counts
      against `safe_to_restart`: refusing is the fail-safe direction, the
      caller gets the per-job detail to judge for itself, and the deploy
      script has an override flag.

  ## Excluding the caller's own session

  An agent-driven deploy runs INSIDE a session on the very host it's about
  to restart, so it would forever refuse to restart itself. `report/2`
  takes a list of session ids to leave out of the counts (the HTTP layer
  exposes it as `?ignore=<id>,<id>`), and echoes them back as `ignored` so
  the exclusion is visible rather than silent.

  ## Degrading honestly

  Agent nodes own no database; they reach it through `OrcaHub.HubRPC`
  (`:erpc` to the hub). If the hub is down, not yet connected, or slow, the
  question is UNANSWERABLE — and an unanswerable drain check must never
  read as "all clear", or the one failure mode this whole feature exists to
  prevent (restarting a busy agent) comes back disguised as a green light.
  So `report/2` returns `state: "unknown"` with `safe_to_restart: false`
  and a `reason` whenever the lookup raises or exits, and callers are
  expected to treat that as a refusal.
  """

  import Ecto.Query, warn: false

  alias OrcaHub.HubRPC
  alias OrcaHub.Jobs.Job
  alias OrcaHub.Repo
  alias OrcaHub.Sessions.Session

  # Session statuses that mean "a turn is in flight on this node". `idle`,
  # `ready` and `error` are all safe to restart through.
  @active_statuses ~w(running waiting compacting)

  # Enough rows for an operator to recognise what they'd be killing without
  # letting a pathological node emit an unbounded response body.
  @max_items 25

  @doc "Session statuses that count as in-flight work."
  def active_statuses, do: @active_statuses

  @doc """
  The JSON-ready restart-readiness report for `node_name` (defaults to this
  node), with `ignore_ids` (session ids) left out of the counts.

  Never raises: a failed lookup becomes the `"unknown"` state.
  """
  def report(node_name \\ to_string(node()), ignore_ids \\ []) do
    case fetch(node_name, ignore_ids) do
      {:ok, counts} ->
        Map.merge(
          %{
            safe_to_restart: counts.sessions.active == 0 and counts.jobs.nonterminal == 0,
            state: "ok",
            node: node_name,
            ignored: ignore_ids
          },
          counts
        )

      {:error, reason} ->
        %{
          safe_to_restart: false,
          state: "unknown",
          node: node_name,
          ignored: ignore_ids,
          reason: reason
        }
    end
  end

  @doc """
  `{:ok, %{sessions: ..., jobs: ...}}` for `node_name`, or `{:error,
  reason}` if the hub couldn't be reached (see the moduledoc).
  """
  def fetch(node_name, ignore_ids \\ []) do
    {:ok, HubRPC.call(__MODULE__, :for_node, [node_name, ignore_ids])}
  rescue
    e -> {:error, Exception.message(e)}
  catch
    kind, reason -> {:error, "#{kind}: #{inspect(reason)}"}
  end

  @doc """
  The raw counts/items for `node_name`, queried straight from the database.

  Runs ON THE HUB — agent nodes reach it through `HubRPC.call/3` in
  `fetch/2`, which is why it's a single public function doing both queries
  rather than two `HubRPC` calls (one erpc round trip, one consistent
  snapshot). `ignore_ids` is applied HERE, in the query, so the counts and
  the item list can never disagree about what was excluded.
  """
  def for_node(node_name, ignore_ids \\ []) when is_binary(node_name) and is_list(ignore_ids) do
    sessions =
      Repo.all(
        from s in Session,
          where: is_nil(s.archived_at),
          where: s.runner_node == ^node_name,
          where: s.status in ^@active_statuses,
          where: s.id not in ^ignore_ids,
          order_by: [asc: s.status, desc: s.updated_at],
          select: %{id: s.id, title: s.title, status: s.status, kind: s.kind}
      )

    jobs =
      Repo.all(
        from j in Job,
          where: j.runner_node == ^node_name,
          where: j.status in ^Job.nonterminal_statuses(),
          order_by: [desc: j.updated_at],
          select: %{id: j.id, label: j.label, status: j.status}
      )

    %{
      sessions: %{
        active: length(sessions),
        running: count_status(sessions, "running"),
        waiting: count_status(sessions, "waiting"),
        compacting: count_status(sessions, "compacting"),
        items: Enum.take(sessions, @max_items)
      },
      jobs: %{
        nonterminal: length(jobs),
        items: Enum.take(jobs, @max_items)
      }
    }
  end

  defp count_status(rows, status), do: Enum.count(rows, &(&1.status == status))
end
