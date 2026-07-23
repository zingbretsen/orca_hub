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
  alias OrcaHub.MCP.CodeExec.MediaSink
  alias OrcaHub.MCP.UpstreamClient

  @kinds ~w(html svg markdown)
  @modes ~w(split full)
  @default_viewports [375, 768, 1440]
  @default_viewport_height 900
  # The MCP endpoint is only reachable in-cluster (Authelia fronts every
  # other origin) — see .context/message-flow.md and the
  # prod-browser-verify-origin memory. playwright-mcp navigates from inside
  # the cluster, so it must use this host, never the LAN/public one.
  @in_cluster_base_url "http://orca-hub.lab.svc.cluster.local:4000"

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
            "LIVE DATA: if this artifact shows numbers that will change later (a dashboard, " <>
            "a report, a live counter), don't re-save the whole document to refresh them — " <>
            "call update_artifact_data instead, which pushes a new `data` snapshot into the " <>
            "SAME artifact without reloading/rewriting its HTML. Your HTML must read " <>
            "`window.ORCA_DATA` on load for the initial snapshot, and listen for live " <>
            "updates with `window.addEventListener(\"message\", (e) => { if (e.data?.type " <>
            "=== \"orca:data\") /* e.data.data is the new snapshot */ })`. The iframe's " <>
            "sandbox has an opaque origin (no `allow-same-origin`), so `fetch()` from " <>
            "inside it can't reach this host — ORCA_DATA/postMessage is the only data path " <>
            "in or out.\n\n" <>
            "USER INPUT: to build a UI that submits data back into this conversation — a " <>
            "dropdown, a form, a region-select, a button — call `window.orca.send(payload)` " <>
            "with any JSON-serializable value (it's injected automatically, no setup " <>
            "needed). The payload is delivered to the user as a message in the session, " <>
            "just like something they typed, so your next turn sees it in the " <>
            "conversation. Design sends as explicit user actions (a submit/confirm " <>
            "button) — never call orca.send automatically or in a loop (e.g. from an " <>
            "interval, a drag/mousemove handler, or on every keystroke); each call becomes " <>
            "a real message, and payloads over ~16KB or sent faster than ~2/sec are " <>
            "dropped.\n\n" <>
            "Verify how it actually renders with screenshot_artifact (drives a shared " <>
            "playwright browser server-side across a few viewport widths and returns " <>
            "saved screenshot file paths for you to Read) before telling the user it's " <>
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
      },
      %{
        "name" => "update_artifact_data",
        "description" =>
          "Push a fresh `data` snapshot into an already-saved artifact WITHOUT reloading " <>
            "its HTML — use this to refresh the numbers behind a dashboard/report you already " <>
            "shipped with save_artifact (e.g. re-run \"top memory consumers\" a week later and " <>
            "push the new numbers into the SAME artifact), instead of re-saving the whole " <>
            "document. Does not bump the artifact's version. Delivered to any already-open " <>
            "viewer live via `postMessage` (see save_artifact's description for the " <>
            "ORCA_DATA/postMessage contract your artifact's HTML must implement to receive " <>
            "it) — no reload, no page refresh.",
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
            "data" => %{
              "type" => "object",
              "description" =>
                "The new data snapshot — a JSON object. Replaces the artifact's entire " <>
                  "previous data payload (not a merge)."
            }
          },
          "required" => ["data"]
        }
      },
      %{
        "name" => "screenshot_artifact",
        "description" =>
          "Collapse the artifact self-preview loop (resize/navigate/screenshot per " <>
            "viewport) into one call: drives the shared playwright-mcp upstream " <>
            "server-side, sequentially, at each requested viewport width, and saves each " <>
            "screenshot to this session's own media directory — returning file paths for " <>
            "you to Read as images before telling the user the artifact is ready.\n\n" <>
            "Requires the playwright-mcp upstream MCP server to be connected/enabled for " <>
            "this session; if it isn't, this returns an error containing the manual " <>
            "recipe (the exact raw URL + steps) so you can drive it yourself with " <>
            "whatever browser tool IS available.\n\n" <>
            "The playwright browser is SHARED state on the hub — another session using it " <>
            "at the same time can interleave with this call (e.g. navigate the shared " <>
            "page out from under it) and produce a screenshot of the wrong content.",
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
            "viewports" => %{
              "type" => "array",
              "items" => %{"type" => "integer"},
              "description" =>
                "Viewport widths in px to screenshot at, one screenshot per width. " <>
                  "Defaults to [375, 768, 1440] (mobile/tablet/desktop)."
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

  def call("update_artifact_data", args, state) do
    data = args["data"]

    cond do
      not is_map(data) ->
        error("update_artifact_data requires a `data` object argument.")

      true ->
        case resolve_artifact(args, state) do
          {:ok, artifact} -> do_update_data(artifact, data)
          {:error, message} -> error(message)
        end
    end
  end

  def call("screenshot_artifact", args, state) do
    viewports = normalize_viewports(args["viewports"])

    case resolve_artifact(args, state) do
      {:ok, artifact} -> do_screenshot(artifact, viewports, state)
      {:error, message} -> error(message)
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

  # ── update_artifact_data ──────────────────────────────────────────────

  defp do_update_data(artifact, data) do
    case HubRPC.update_artifact_data(artifact, data) do
      {:ok, artifact} ->
        text(
          Jason.encode!(%{
            id: artifact.id,
            name: artifact.name,
            version: artifact.version,
            raw_url: raw_url(artifact),
            data_updated: true
          })
        )

      {:error, changeset} ->
        error("Failed to update artifact data: #{inspect(changeset.errors)}")
    end
  end

  # ── screenshot_artifact ───────────────────────────────────────────────
  #
  # Drives playwright-mcp directly via `UpstreamClient.call_tool/3` — the
  # exact same hub-aware entry point `OrcaHub.MCP.Server` and
  # `MCP.CodeExec.Dispatcher` use for every upstream tool call, so this works
  # unchanged whether the calling session's MCP connection lives on the hub
  # or an agent node (it forwards to the hub via `:erpc` there, same as
  # every other upstream call). `filename` is deliberately never passed to
  # `browser_take_screenshot` — playwright-mcp would then write the file
  # inside its OWN pod and hand back only an unreachable link (see
  # `MCP.CodeExec.Dispatcher`'s moduledoc) — instead the raw image bytes are
  # requested inline and saved locally via `MediaSink`, on this session's
  # own runner node, exactly like the code-exec self-preview loop does.

  defp normalize_viewports(widths) when is_list(widths) do
    case Enum.filter(widths, &(is_integer(&1) and &1 > 0)) do
      [] -> @default_viewports
      widths -> widths
    end
  end

  defp normalize_viewports(_widths), do: @default_viewports

  defp do_screenshot(artifact, viewports, state) do
    render_screenshots(artifact, viewports, state[:orca_session_id])
  end

  @doc """
  Public and dependency-injectable — mirrors `PlaywrightUpload.maybe_rewrite_paths/4`'s
  `upload_fun` pattern — so tests can exercise the full happy/error paths
  without touching the live `UpstreamClient` GenServer or the network.

    * `available?` (arity 0) decides whether playwright is connected;
      defaults to a real `UpstreamClient.prefixes/0` check.
    * `call_fn` (arity 3, `tool_name, arguments, opts -> envelope`) performs
      one upstream tool call; defaults to the real
      `UpstreamClient.call_tool/3` (itself hub-aware — see the moduledoc
      note above).
  """
  def render_screenshots(
        artifact,
        viewports,
        session_id,
        available? \\ &playwright_available?/0,
        call_fn \\ &UpstreamClient.call_tool/3
      ) do
    if available?.() do
      url = absolute_raw_url(artifact)

      screenshots =
        Enum.map(viewports, &viewport_screenshot(&1, url, artifact, session_id, call_fn))

      text(
        Jason.encode!(%{
          id: artifact.id,
          name: artifact.name,
          raw_url: raw_url(artifact),
          screenshots: screenshots
        })
      )
    else
      error(manual_recipe(artifact))
    end
  end

  defp playwright_available?, do: "playwright" in UpstreamClient.prefixes()

  # Sequential by construction — Enum.map/2 over one process, one viewport at
  # a time, matching the tool description's "sequentially" promise (the
  # shared upstream browser can't usefully be resized/navigated concurrently
  # from a single call anyway).
  defp viewport_screenshot(width, url, artifact, session_id, call_fn) do
    with {:ok, _} <- resize(width, session_id, call_fn),
         {:ok, _} <- navigate(url, session_id, call_fn),
         {:ok, content} <- screenshot(session_id, call_fn),
         {:ok, bytes, mime} <- first_image_block(content) do
      path = save_screenshot(bytes, mime, artifact, width, session_id)
      %{width: width, path: path}
    else
      {:error, message} -> %{width: width, error: message}
    end
  end

  defp resize(width, session_id, call_fn),
    do:
      call_playwright(
        "browser_resize",
        %{"width" => width, "height" => @default_viewport_height},
        session_id,
        call_fn
      )

  defp navigate(url, session_id, call_fn),
    do: call_playwright("browser_navigate", %{"url" => url}, session_id, call_fn)

  defp screenshot(session_id, call_fn) do
    case call_playwright("browser_take_screenshot", %{}, session_id, call_fn) do
      {:ok, %{"content" => content}} when is_list(content) -> {:ok, content}
      {:ok, other} -> {:error, "unexpected browser_take_screenshot response: #{inspect(other)}"}
      {:error, message} -> {:error, message}
    end
  end

  defp call_playwright(name, args, session_id, call_fn) do
    case call_fn.("playwright__#{name}", args, orca_session_id: session_id) do
      %{"isError" => true} = result -> {:error, upstream_error_text(result)}
      result -> {:ok, result}
    end
  end

  defp upstream_error_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} -> text
      other -> inspect(other)
    end)
    |> Enum.join(" ")
  end

  defp upstream_error_text(other), do: inspect(other)

  defp first_image_block(content) do
    case Enum.find(content, &(&1["type"] == "image")) do
      %{"data" => data, "mimeType" => mime} ->
        case decode_base64(data) do
          {:ok, bytes} -> {:ok, bytes, mime}
          :error -> {:error, "failed to decode screenshot image data"}
        end

      _ ->
        {:error, "browser_take_screenshot did not return an image"}
    end
  end

  defp decode_base64(data) do
    case Base.decode64(data) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> Base.decode64(data, padding: false)
    end
  end

  defp save_screenshot(bytes, mime, artifact, width, session_id) do
    root = MediaSink.media_root_for(session_id)
    File.mkdir_p!(root)
    ext = MediaSink.ext_for_mime(mime)
    filename = "artifact-#{MediaSink.sanitize_for_filename(artifact.name)}-#{width}px.#{ext}"
    path = Path.join(root, filename)
    File.write!(path, bytes)
    path
  end

  defp absolute_raw_url(artifact), do: @in_cluster_base_url <> raw_url(artifact)

  defp manual_recipe(artifact) do
    url = absolute_raw_url(artifact)

    "The playwright-mcp upstream server isn't connected/enabled for this session, so " <>
      "screenshot_artifact can't drive it server-side. If a playwright browser tool is " <>
      "reachable some other way, drive it yourself: for each viewport width " <>
      "(default 375, 768, 1440) call browser_resize({width, height: #{@default_viewport_height}}), " <>
      "then browser_navigate({url: #{inspect(url)}}), then browser_take_screenshot() — " <>
      "omit `filename` so it returns the image bytes inline instead of saving them " <>
      "unreachably inside playwright's own pod."
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
