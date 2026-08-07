defmodule OrcaHubWeb.IssueLive.Show do
  @moduledoc """
  Single-issue view for a durable work item (issues_spec.md). Renders the
  full Phase 2a field set — short key, `kind`, `plan`/`premise`/
  `resolution`, frozen `commits`/`attempts` once closed, `superseded_by`,
  `closed_at`/`closed_by_session_id` — and is the one place in this UI
  that can change status: closing (via `OrcaHub.HubRPC.close_issue/2`,
  which freezes `commits`/`attempts` exactly like the MCP tool path does)
  and reopening (via `HubRPC.reopen_issue/2`, the §3.5.1
  preserve-then-clear sequence). The legacy arity-1 `close_issue/1`/
  `reopen_issue/1` (no freeze/archive behavior) are NOT used here — see
  `OrcaHub.Issues`' moduledoc for why both still exist.

  `id` in the route accepts any of the three forms `OrcaHub.Issues.resolve_id/1`
  understands — short key (`ORCA-142`), full UUID, or an unambiguous hex
  prefix — resolved once at mount.

  Attempts are a LIVE, per-attempt-session git-log fan-out while the issue
  is open/in_progress (issues_spec.md §3.5) — deliberately never loaded on
  the index page, and loaded here off the critical path via `start_async`
  (same pattern `SessionLive.Show` uses for its commit panel) rather than
  blocking first paint. Once closed/abandoned, `attempts` is a flat,
  already-loaded DB column (§4.3) — no async fetch needed.
  """
  use OrcaHubWeb, :live_view

  alias OrcaHub.{Cluster, HubRPC, Sessions}

  @open_statuses ["open", "in_progress"]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case HubRPC.resolve_issue_id(id) do
      {:ok, issue} ->
        {:ok, socket |> assign_issue(issue) |> maybe_load_attempts()}

      {:error, _message} ->
        {:ok,
         socket
         |> put_flash(:error, "No issue found with id #{id}.")
         |> push_navigate(to: ~p"/issues")}
    end
  end

  defp assign_issue(socket, issue) do
    key = HubRPC.render_issue_key(issue)
    project = issue.project_id && HubRPC.get_project(issue.project_id)

    socket
    |> assign(
      page_title: Enum.join(Enum.reject([key, issue.title], &is_nil/1), " — "),
      issue: issue,
      key: key,
      project: project,
      superseded_by_issue: superseded_by_summary(issue.superseded_by_issue_id),
      closing: false,
      close_form: default_close_form(),
      close_error: nil,
      live_attempts: nil,
      expanded_commit: nil,
      commit_detail: nil
    )
  end

  defp default_close_form,
    do: %{"outcome" => "resolved", "resolution" => "", "superseded_by" => ""}

  defp superseded_by_summary(nil), do: nil

  defp superseded_by_summary(issue_id) do
    case HubRPC.get_issue(issue_id) do
      nil ->
        nil

      issue ->
        %{
          id: issue.id,
          key: HubRPC.render_issue_key(issue),
          title: issue.title,
          status: issue.status
        }
    end
  end

  # -- Close --

  @impl true
  def handle_event("open_close_form", _params, socket) do
    {:noreply, assign(socket, closing: true, close_form: default_close_form(), close_error: nil)}
  end

  def handle_event("cancel_close", _params, socket) do
    {:noreply, assign(socket, closing: false, close_error: nil)}
  end

  def handle_event(
        "submit_close",
        %{"outcome" => outcome, "resolution" => resolution, "superseded_by" => superseded_by},
        socket
      ) do
    form = %{"outcome" => outcome, "resolution" => resolution, "superseded_by" => superseded_by}

    with {:ok, superseded_by_id} <- resolve_superseded_by(superseded_by, socket.assigns.issue),
         attrs = %{
           outcome: outcome,
           resolution: String.trim(resolution),
           superseded_by_issue_id: superseded_by_id
         },
         {:ok, issue} <- HubRPC.close_issue(socket.assigns.issue, attrs) do
      {:noreply,
       socket
       |> assign_issue(issue)
       |> maybe_load_attempts()
       |> put_flash(:info, "Issue closed.")}
    else
      {:error, reason} ->
        {:noreply, assign(socket, close_form: form, close_error: close_error_message(reason))}
    end
  end

  def handle_event("reopen", _params, socket) do
    case HubRPC.reopen_issue(socket.assigns.issue, nil) do
      {:ok, issue} ->
        {:noreply,
         socket
         |> assign_issue(issue)
         |> maybe_load_attempts()
         |> put_flash(:info, "Issue reopened.")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to reopen issue.")}
    end
  end

  def handle_event("toggle_commit_detail", %{"hash" => hash}, socket) do
    if socket.assigns.expanded_commit == hash do
      {:noreply, assign(socket, expanded_commit: nil, commit_detail: nil)}
    else
      detail =
        case fetch_commit_detail(socket.assigns.project, hash) do
          %{} = detail -> detail
          _ -> nil
        end

      {:noreply, assign(socket, expanded_commit: hash, commit_detail: detail)}
    end
  end

  defp resolve_superseded_by(superseded_by, issue) do
    case String.trim(superseded_by || "") do
      "" ->
        {:ok, nil}

      id ->
        case HubRPC.resolve_issue_id(id) do
          {:ok, %{id: superseding_id}} when superseding_id == issue.id ->
            {:error, "An issue cannot supersede itself."}

          {:ok, superseding} ->
            {:ok, superseding.id}

          {:error, message} ->
            {:error, message}
        end
    end
  end

  defp close_error_message(:invalid_outcome), do: "Choose an outcome."
  defp close_error_message(:resolution_required), do: "A resolution is required to close."
  defp close_error_message(message) when is_binary(message), do: message
  defp close_error_message(%Ecto.Changeset{} = cs), do: changeset_error_message(cs)
  defp close_error_message(_other), do: "Could not close this issue."

  defp changeset_error_message(changeset) do
    changeset.errors
    |> Enum.map_join(", ", fn {field, {msg, _opts}} -> "#{field} #{msg}" end)
  end

  # -- Commit detail (frozen `commits`, same affordance as SessionLive.Show) --

  defp fetch_commit_detail(nil, _hash), do: nil

  defp fetch_commit_detail(project, hash) do
    node = Cluster.project_node_for(project)
    Cluster.rpc(node, Sessions, :get_commit_detail, [project.directory, hash])
  end

  # -- Live attempts (async, open/in_progress only — issues_spec.md §3.5) --

  defp maybe_load_attempts(socket) do
    if connected?(socket) and socket.assigns.issue.status in @open_statuses do
      issue = socket.assigns.issue

      start_async(socket, :live_attempts, fn ->
        HubRPC.live_issue_attempts(issue)
      end)
      |> assign(:live_attempts, nil)
    else
      socket
    end
  end

  @impl true
  def handle_async(:live_attempts, result, socket) do
    case result do
      {:ok, attempts} when is_list(attempts) ->
        {:noreply, assign(socket, :live_attempts, attempts)}

      _ ->
        {:noreply, socket}
    end
  end

  # -- Template helpers --

  @doc false
  def attempts_for(%{status: status}, live_attempts) when status in @open_statuses do
    live_attempts || :loading
  end

  def attempts_for(issue, _live_attempts), do: issue.attempts

  @doc false
  def mfield(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  @doc false
  def frozen_attempt?(attempt), do: not is_nil(mfield(attempt, :outcome))

  # Live attempts beyond OrcaHub.Issues' full-detail cap (issues_spec.md
  # §13 risk 5) come back as a bare `%{session_id, status}` — no
  # last_assistant_text/commits/progress fields to render.
  @doc false
  def live_full_detail?(attempt),
    do:
      Map.has_key?(attempt, :last_assistant_text) or Map.has_key?(attempt, "last_assistant_text")

  @doc false
  def format_timestamp(nil), do: "—"
  def format_timestamp(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  def format_timestamp(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  def format_timestamp(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> iso
    end
  end

  def format_timestamp(other), do: to_string(other)

  def status_badge_class(status) do
    [
      "badge",
      status == "open" && "badge-info",
      status == "in_progress" && "badge-warning",
      status == "closed" && "badge-success",
      status == "abandoned" && "badge-neutral",
      status in ["idle"] && "badge-success",
      status in ["running"] && "badge-warning",
      status in ["error"] && "badge-error",
      status in ["ready"] && "badge-ghost",
      status in ["waiting"] && "badge-info",
      status in ["compacting"] && "badge-warning"
    ]
  end
end
