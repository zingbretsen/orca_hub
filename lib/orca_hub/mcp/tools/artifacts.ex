defmodule OrcaHub.MCP.Tools.Artifacts do
  @moduledoc """
  MCP tools for creating and browsing persistent, rich-UI artifacts
  (self-contained HTML/SVG/markdown documents) rendered client-side in a
  sandboxed iframe — see `OrcaHub.Artifacts` for the storage/rendering
  design.

  Follows the same "broadcast, let the LiveView react" pattern as
  `OrcaHub.MCP.Tools.Files`'s `open_file`: instead of the tool pushing UI
  state directly, it broadcasts `{:open_artifact, artifact_id, mode}` on
  `"session:<session_id>"` and `SessionLive.Show` handles opening the tab
  (or navigating to the fullscreen viewer).

  `save_artifact`/`open_artifact`/`list_artifacts` all resolve the calling
  session's project via `state.orca_session_id`, since artifacts are stored
  per project, not per session — `get_artifact` is the one exception when
  called with an `artifact_id` (not `name`): it fetches directly by id with
  no project scoping, so a later session (possibly in a different project
  directory, e.g. an orchestrator) can still read back an old artifact's
  content to iterate on it.
  """

  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.Artifacts.HtmlValidator
  alias OrcaHub.HubRPC

  @kinds ~w(html svg markdown)
  @modes ~w(split full)

  def list do
    [
      %{
        "name" => "save_artifact",
        "description" =>
          "Create or update a persistent, rich-UI artifact shown to the user in a side " <>
            "panel next to the chat (or fullscreen). Use this instead of dumping HTML in " <>
            "a chat message when you want to show a real interactive UI: a dashboard, a " <>
            "diagram, a report, a small tool. It survives after this session ends and can " <>
            "be reopened or iterated on later.\n\n" <>
            "Content runs in a sandboxed iframe (`sandbox=\"allow-scripts\"`, no " <>
            "`allow-same-origin`) — it has NO access to cookies, auth, or the parent page " <>
            "DOM, so a full self-contained HTML document with inline <style> and <script> " <>
            "works best; CDN scripts (Chart.js, mermaid, Tailwind Play CDN, etc.) are " <>
            "allowed and commonly used. `kind: \"svg\"` and `kind: \"markdown\"` are also " <>
            "supported for simpler content.\n\n" <>
            "Saving under a `name` that already exists in this project UPDATES that " <>
            "artifact in place (and bumps its version) rather than creating a new one — " <>
            "reuse the same name to iterate on one artifact across turns/sessions.\n\n" <>
            "You can verify how it actually renders by navigating a playwright browser " <>
            "(when that upstream MCP server is enabled) to the returned raw URL — " <>
            "http://orca-hub.lab.svc.cluster.local:4000<raw_url> — and taking screenshots " <>
            "at a few viewport widths (e.g. 375, 768, 1280) before telling the user it's " <>
            "ready.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" =>
                "Stable name for this artifact within the project. Reuse the same name " <>
                  "across calls to update/iterate on the same artifact instead of creating " <>
                  "a new one."
            },
            "content" => %{
              "type" => "string",
              "description" =>
                "The full artifact content. For kind=html, a complete self-contained HTML " <>
                  "document (inline CSS/JS, optional CDN <script> tags) works best."
            },
            "kind" => %{
              "type" => "string",
              "description" => "One of \"html\" (default), \"svg\", or \"markdown\"."
            },
            "open" => %{
              "type" => "boolean",
              "description" =>
                "Whether to open the artifact in the user's viewer immediately after " <>
                  "saving. Defaults to true."
            },
            "mode" => %{
              "type" => "string",
              "description" =>
                "Where to open it when `open` is true: \"split\" (side panel, default) or " <>
                  "\"full\" (fullscreen viewer)."
            }
          },
          "required" => ["name", "content"]
        }
      },
      %{
        "name" => "open_artifact",
        "description" =>
          "Open an existing artifact in the user's viewer, by name (within this session's " <>
            "project) or by artifact_id.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" => "The artifact's name, within this session's project."
            },
            "artifact_id" => %{
              "type" => "string",
              "description" => "The artifact's id (alternative to `name`)."
            },
            "mode" => %{
              "type" => "string",
              "description" => "\"split\" (side panel, default) or \"full\" (fullscreen viewer)."
            }
          }
        }
      },
      %{
        "name" => "list_artifacts",
        "description" =>
          "List the artifacts saved for this session's project (id, name, kind, version, " <>
            "last updated) — check this before save_artifact if you want to know whether " <>
            "a given name already exists.",
        "inputSchema" => %{"type" => "object", "properties" => %{}}
      },
      %{
        "name" => "get_artifact",
        "description" =>
          "Fetch an artifact's full content by name (within this session's project) or by " <>
            "artifact_id, so it can be inspected or iterated on (e.g. from a later " <>
            "session).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" => "The artifact's name, within this session's project."
            },
            "artifact_id" => %{
              "type" => "string",
              "description" => "The artifact's id (alternative to `name`)."
            }
          }
        }
      }
    ]
  end

  def call("save_artifact", args, state) do
    name = args["name"]
    content = args["content"]
    kind = normalize_kind(args["kind"])
    open? = Map.get(args, "open", true)
    mode = normalize_mode(args["mode"])

    cond do
      not is_binary(name) or name == "" ->
        error("save_artifact requires a non-empty `name` string argument.")

      not is_binary(content) or content == "" ->
        error("save_artifact requires a non-empty `content` string argument.")

      kind not in @kinds ->
        error("save_artifact `kind` must be one of: #{Enum.join(@kinds, ", ")}.")

      true ->
        do_save(name, content, kind, open?, mode, state)
    end
  end

  def call("open_artifact", args, state) do
    mode = normalize_mode(args["mode"])

    case resolve_artifact(args, state) do
      {:ok, artifact} -> do_open(artifact, mode, state)
      {:error, message} -> error(message)
    end
  end

  def call("list_artifacts", _args, state) do
    with_project(state, fn project_id ->
      artifacts =
        project_id
        |> HubRPC.list_artifacts_for_project()
        |> Enum.map(&summary/1)

      text(Jason.encode!(%{"count" => length(artifacts), "artifacts" => artifacts}))
    end)
  end

  def call("get_artifact", args, state) do
    case resolve_artifact(args, state) do
      {:ok, artifact} ->
        text(
          Jason.encode!(%{
            id: artifact.id,
            name: artifact.name,
            kind: artifact.kind,
            version: artifact.version,
            content: artifact.content,
            raw_url: raw_url(artifact),
            updated_at: artifact.updated_at
          })
        )

      {:error, message} ->
        error(message)
    end
  end

  # ── save_artifact ─────────────────────────────────────────────────────

  defp do_save(name, content, kind, open?, mode, state) do
    with_project(state, fn project_id ->
      attrs = %{
        project_id: project_id,
        session_id: state[:orca_session_id],
        name: name,
        kind: kind,
        content: content
      }

      case HubRPC.save_artifact(attrs) do
        {:ok, artifact} ->
          if open?, do: broadcast_open(state, artifact.id, mode)
          text(Jason.encode!(save_result(artifact, kind, content, open?)))

        {:error, changeset} ->
          error("Failed to save artifact: #{inspect(changeset.errors)}")
      end
    end)
  end

  defp save_result(artifact, "html", content, opened?) do
    base_result(artifact, opened?)
    |> Map.put(:warnings, HtmlValidator.validate(content))
  end

  defp save_result(artifact, _kind, _content, opened?), do: base_result(artifact, opened?)

  defp base_result(artifact, opened?) do
    %{
      id: artifact.id,
      name: artifact.name,
      kind: artifact.kind,
      version: artifact.version,
      raw_url: raw_url(artifact),
      opened: opened?
    }
  end

  # ── open_artifact ─────────────────────────────────────────────────────

  defp do_open(artifact, mode, state) do
    broadcast_open(state, artifact.id, mode)

    text(
      Jason.encode!(%{
        id: artifact.id,
        name: artifact.name,
        raw_url: raw_url(artifact),
        opened: true,
        mode: mode
      })
    )
  end

  defp broadcast_open(state, artifact_id, mode) do
    case state[:orca_session_id] do
      nil ->
        :ok

      session_id ->
        Phoenix.PubSub.broadcast(
          OrcaHub.PubSub,
          "session:#{session_id}",
          {:open_artifact, artifact_id, mode}
        )
    end
  end

  # ── shared resolution helpers ────────────────────────────────────────

  defp resolve_artifact(%{"artifact_id" => id}, _state) when is_binary(id) and id != "" do
    case HubRPC.get_artifact(id) do
      nil -> {:error, "No artifact found with id #{id}."}
      artifact -> {:ok, artifact}
    end
  end

  defp resolve_artifact(%{"name" => name}, state) when is_binary(name) and name != "" do
    with_project_result(state, fn project_id ->
      case HubRPC.get_artifact_by_name(project_id, name) do
        nil -> {:error, "No artifact named #{inspect(name)} in this project."}
        artifact -> {:ok, artifact}
      end
    end)
  end

  defp resolve_artifact(_args, _state) do
    {:error, "Provide either `name` or `artifact_id`."}
  end

  defp with_project(state, fun) do
    case resolve_project_id(state) do
      {:ok, project_id} -> fun.(project_id)
      {:error, message} -> error(message)
    end
  end

  defp with_project_result(state, fun) do
    case resolve_project_id(state) do
      {:ok, project_id} -> fun.(project_id)
      {:error, _message} = error -> error
    end
  end

  defp resolve_project_id(state) do
    case state[:orca_session_id] do
      nil ->
        {:error, "No OrcaHub session linked to this MCP connection. Cannot resolve a project."}

      session_id ->
        case HubRPC.get_session(session_id) do
          nil -> {:error, "Session #{session_id} not found."}
          %{project_id: nil} -> {:error, "This session has no associated project."}
          session -> {:ok, session.project_id}
        end
    end
  end

  defp normalize_kind(nil), do: "html"
  defp normalize_kind(kind) when is_binary(kind), do: kind

  defp normalize_mode(mode) when mode in @modes, do: mode
  defp normalize_mode(_mode), do: "split"

  defp summary(artifact) do
    %{
      id: artifact.id,
      name: artifact.name,
      kind: artifact.kind,
      version: artifact.version,
      updated_at: artifact.updated_at
    }
  end

  defp raw_url(artifact), do: "/artifacts/#{artifact.id}/raw?v=#{artifact.version}"
end
