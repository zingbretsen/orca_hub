defmodule OrcaHub.SessionHeartbeat.Digest do
  @moduledoc """
  Builds the compact auto-digest a heartbeat appends to its message for
  watched sessions (`schedule_heartbeat`'s `watch_session_ids`/`watch_children`).

  Resolution happens fresh on every call — `watch_children` is expanded via
  `parent_session_id` at call time, not cached, so children spawned after the
  heartbeat was scheduled are picked up automatically. Archived or deleted
  watched sessions drop out silently rather than erroring.
  """

  alias OrcaHub.{Cluster, HubRPC}

  @error_detail_limit 160

  @doc """
  Resolves `watch_session_ids` plus (if `watch_children?`) `caller_session_id`'s
  current non-archived children, and renders a digest for whatever's left.

  Returns `{digest, snapshot}` where `digest` is a string to append to the
  heartbeat message (or `nil` if nothing resolved) and `snapshot` is a
  `session_id => {status, progress_phase, progress_note, last_activity_at}`
  map — the change-detection input for `only_if_changed` (see `changed?/2`).
  """
  def build(caller_session_id, watch_session_ids, watch_children?) do
    sessions =
      caller_session_id
      |> resolve_ids(watch_session_ids || [], watch_children? == true)
      |> fetch_sessions()

    if sessions == [] do
      {nil, %{}}
    else
      activity_by_id = HubRPC.activity_metadata(Enum.map(sessions, & &1.id))
      commit_by_id = fetch_last_commits(sessions)

      digest =
        "\n\n[Watch] #{length(sessions)} session(s):\n" <>
          (sessions
           |> Enum.map(&format_line(&1, activity_by_id, commit_by_id))
           |> Enum.join("\n"))

      snapshot = Map.new(sessions, &{&1.id, snapshot_entry(&1, activity_by_id)})

      {digest, snapshot}
    end
  end

  @doc "Whether `new_snapshot` differs from `old_snapshot`. A nil `old_snapshot` (no previous fire) always counts as changed."
  def changed?(nil, _new_snapshot), do: true
  def changed?(old_snapshot, new_snapshot), do: old_snapshot != new_snapshot

  # -------------------------------------------------------------------
  # Private
  # -------------------------------------------------------------------

  defp resolve_ids(caller_session_id, watch_session_ids, watch_children?) do
    children_ids =
      if watch_children? do
        HubRPC.search_all_sessions(%{parent_session_id: caller_session_id})
        |> Enum.map(& &1.id)
      else
        []
      end

    (watch_session_ids ++ children_ids) |> Enum.uniq()
  end

  defp fetch_sessions(ids) do
    ids
    |> Enum.map(&HubRPC.get_session/1)
    |> Enum.filter(&(&1 && is_nil(&1.archived_at)))
  end

  # Dedupes by {node, directory} so sessions sharing a working directory only
  # trigger one `git log` per directory — mirrors
  # `MCP.Tools.Sessions.fetch_last_commits/1`.
  defp fetch_last_commits(sessions) do
    tagged =
      Enum.map(sessions, fn s -> {s.id, Cluster.runner_node_for(s) || node(), s.directory} end)

    commit_by_pair =
      tagged
      |> Enum.map(fn {_id, node, dir} -> {node, dir} end)
      |> Enum.uniq()
      |> Map.new(fn {node, dir} -> {{node, dir}, fetch_last_commit(node, dir)} end)

    Map.new(tagged, fn {id, node, dir} -> {id, commit_by_pair[{node, dir}]} end)
  end

  defp fetch_last_commit(node, directory) do
    case Cluster.rpc(node, OrcaHub.Sessions, :git_head_info, [directory]) do
      %{} = info -> info
      _ -> nil
    end
  end

  defp format_line(session, activity_by_id, commit_by_id) do
    activity = Map.get(activity_by_id, session.id, %{})
    commit = Map.get(commit_by_id, session.id)

    name = session.title || "session #{String.slice(session.id, 0, 8)}"

    [
      "- #{name} [#{session.status}]",
      format_phase(session),
      format_activity(activity),
      format_commit(commit),
      format_error(session)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" | ")
  end

  defp format_phase(%{progress_phase: nil}), do: ""

  defp format_phase(%{progress_phase: phase, progress_note: note}) do
    if note && note != "", do: "#{phase} (#{note})", else: phase
  end

  defp format_activity(%{messages_5m: m, tool_calls_5m: t}) when is_integer(m) and is_integer(t),
    do: "#{m}msg/#{t}tool (5m)"

  defp format_activity(_), do: ""

  defp format_commit(nil), do: ""
  defp format_commit(%{short_sha: sha, subject: subject}), do: "commit #{sha} \"#{subject}\""

  defp format_error(%{status: "error", error_detail: detail})
       when is_binary(detail) and detail != "",
       do: String.slice(detail, 0, @error_detail_limit)

  defp format_error(_), do: ""

  defp snapshot_entry(session, activity_by_id) do
    activity = Map.get(activity_by_id, session.id, %{})

    {session.status, session.progress_phase, session.progress_note,
     Map.get(activity, :last_activity_at)}
  end
end
