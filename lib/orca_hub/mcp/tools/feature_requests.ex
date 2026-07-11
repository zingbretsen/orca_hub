defmodule OrcaHub.MCP.Tools.FeatureRequests do
  @moduledoc """
  MCP tool letting any agent session file platform friction against OrcaHub
  itself as a queryable backlog item, instead of silently working around it
  (e.g. writing a scratch feedback file to disk — see the incident that
  motivated this tool).

  Always files against the project registered for `@orca_hub_directory`
  (the OrcaHub codebase's own project), regardless of the calling session's
  own directory — this is deliberately not "file an issue in my own
  project," it's "tell the OrcaHub maintainers about a rough edge in the
  platform." Backed by `OrcaHub.Issues`, a minimal reintroduction of the
  context removed in `3ebb3fe` (see its moduledoc) — no migration needed,
  the `issues` table was left in place.
  """
  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.HubRPC
  alias OrcaHub.Issues.Issue

  @orca_hub_directory "/home/zach/orca_hub"
  @title_prefix "[agent-fr] "

  def list do
    [
      %{
        "name" => "file_feature_request",
        "description" =>
          "File a feature request or platform-friction report against the OrcaHub " <>
            "codebase itself — NOT the calling session's own project — so friction " <>
            "becomes a queryable backlog item instead of getting silently worked " <>
            "around. Use this when you hit a missing tool, an awkward workflow, a " <>
            "confusing error, or a doc gap in OrcaHub/its MCP tools/its UI. Light " <>
            "dedup: if an open agent-filed issue with a similar title already " <>
            "exists, no new issue is created — the existing one is returned instead.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "title" => %{
              "type" => "string",
              "description" => "Short title for the feature request."
            },
            "description" => %{
              "type" => "string",
              "description" =>
                "The pain point, the proposed change, and any evidence from this " <>
                  "session — what you tried, what broke, what would have helped."
            },
            "category" => %{
              "type" => "string",
              "description" =>
                "Optional free-text category, e.g. tooling, observability, coordination, docs."
            }
          },
          "required" => ["title", "description"]
        }
      }
    ]
  end

  def call("file_feature_request", args, state) do
    title = args["title"]
    description = args["description"]

    cond do
      not is_binary(title) or title == "" ->
        error("file_feature_request requires a non-empty `title` string argument.")

      not is_binary(description) or description == "" ->
        error("file_feature_request requires a non-empty `description` string argument.")

      true ->
        file_request(title, description, args["category"], state)
    end
  end

  defp file_request(title, description, category, state) do
    case HubRPC.get_project_by_directory(@orca_hub_directory) do
      nil ->
        error(
          "No OrcaHub project is registered for #{@orca_hub_directory} — cannot file a " <>
            "feature request. Register that project first."
        )

      project ->
        full_title = @title_prefix <> title

        case find_similar_open_issue(project.id, full_title) do
          %Issue{} = existing ->
            text(Jason.encode!(dedup_result(existing)))

          nil ->
            create_request(project.id, full_title, description, category, state)
        end
    end
  end

  defp create_request(project_id, full_title, description, category, state) do
    attrs = %{
      title: full_title,
      description: description <> "\n\n" <> provenance_block(category, state),
      project_id: project_id,
      status: "open"
    }

    case HubRPC.create_issue(attrs) do
      {:ok, issue} ->
        text(Jason.encode!(created_result(issue)))

      {:error, changeset} ->
        error("Failed to file feature request: #{inspect(changeset.errors)}")
    end
  end

  # ── dedup ──────────────────────────────────────────────────────────────
  # Simple and cheap on purpose: case-insensitive substring or word-overlap
  # against OPEN, agent-filed (title-prefixed) issues only — never matches a
  # human-filed issue, and never reopens/touches a closed one.

  defp find_similar_open_issue(project_id, full_title) do
    project_id
    |> HubRPC.list_open_issues_for_project()
    |> Enum.filter(&String.starts_with?(&1.title, @title_prefix))
    |> Enum.find(&similar_title?(&1.title, full_title))
  end

  defp similar_title?(existing_title, new_title) do
    existing_norm = normalize_title(existing_title)
    new_norm = normalize_title(new_title)

    String.contains?(existing_norm, new_norm) or String.contains?(new_norm, existing_norm) or
      word_overlap_ratio(existing_norm, new_norm) >= 0.6
  end

  defp normalize_title(title) do
    title
    |> String.trim_leading(@title_prefix)
    |> String.downcase()
    |> String.trim()
  end

  defp word_overlap_ratio(a, b) do
    words_a = title_words(a)
    words_b = title_words(b)

    if words_a == [] or words_b == [] do
      0.0
    else
      common =
        MapSet.intersection(MapSet.new(words_a), MapSet.new(words_b))
        |> MapSet.size()

      common / min(length(words_a), length(words_b))
    end
  end

  defp title_words(title) do
    title
    |> String.split(~r/\W+/, trim: true)
    |> Enum.filter(&(String.length(&1) > 2))
  end

  # ── result shaping ────────────────────────────────────────────────────

  defp provenance_block(category, state) do
    """
    ---
    Filed automatically via file_feature_request.
    Session: #{state[:orca_session_id] || "unknown"}
    Node: #{OrcaHub.Cluster.node_name(node())}
    Date: #{Date.utc_today()}
    Category: #{category || "uncategorized"}
    """
    |> String.trim()
  end

  defp created_result(issue) do
    %{
      id: issue.id,
      title: issue.title,
      url: issue_url(issue.id),
      created: true,
      deduped: false
    }
  end

  defp dedup_result(issue) do
    %{
      id: issue.id,
      title: issue.title,
      url: issue_url(issue.id),
      created: false,
      deduped: true,
      message:
        "A similar open agent-filed issue already exists — not creating a duplicate. " <>
          "OrcaHub.Issues.append_note/2 supports appending a note to record new evidence " <>
          "on the existing issue, though it isn't exposed as its own MCP tool yet; mention " <>
          "significant new evidence to a human maintainer in the meantime."
    }
  end

  # The Issues UI/routes were removed along with the rest of the feature in
  # 3ebb3fe (see OrcaHub.Issues moduledoc) — this path doesn't resolve yet.
  # Returned anyway as a stable identifier/convention for when a read-only
  # issue view is restored.
  defp issue_url(id), do: "/issues/#{id}"
end
