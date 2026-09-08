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
  alias OrcaHub.Artifacts.Render
  alias OrcaHub.{Files, HubRPC, PathConfinement}
  alias OrcaHub.MCP.CodeExec.MediaSink

  @kinds ~w(html svg markdown)
  @modes ~w(split full)
  @default_viewports [375, 768, 1440]
  @default_viewport_height 900
  @screenshot_timeout_ms 30_000

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
            "Provide exactly one of `content` (the content as a string) or `content_path` " <>
            "(a path to a file already on disk, read directly on this session's own node " <>
            "so the bytes never have to pass through your own context) — use " <>
            "`content_path` for anything you built/tested on disk across multiple turns, " <>
            "since re-reading a large file into context just to re-emit it as a string is " <>
            "pure overhead.\n\n" <>
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
            "Verify how it actually renders with screenshot_artifact (renders it in a " <>
            "local headless browser on this session's node across a few viewport widths " <>
            "and returns saved screenshot file paths for you to Read) before telling the " <>
            "user it's ready.\n\n" <>
            "USER STATE: to make a checklist/form remember what the user ticked/typed " <>
            "across reloads, tabs, and devices — with zero JS — mark each input " <>
            "`data-orca-persist=\"some-key\"`. It's restored on load (checkbox/radio -> " <>
            "checked, everything else -> value) and written through automatically " <>
            "(`change` immediately, `input` debounced ~300ms). For anything the " <>
            "declarative attribute can't express, call `window.orca.setState(patch)` " <>
            "with a flat JSON object yourself (shallow-merged into storage — existing " <>
            "keys not in `patch` are left alone; a key set to `null` deletes it) and " <>
            "`window.orca.getState()` to read the current state back synchronously. " <>
            "State lives under the reserved `_user_state` key in this artifact's `data` " <>
            "(visible via get_artifact) and survives re-saving this artifact's content, " <>
            "but is lost if you rename it (a rename is a different artifact row). It's " <>
            "shared by every viewer of this artifact, not scoped per user. There's no " <>
            "dedicated reset tool — call update_artifact_data with " <>
            "`data: {\"_user_state\": {}}` to clear it. Writing state never wakes this " <>
            "or any other session and never costs tokens — it's a direct DB write.",
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
                  "document (inline CSS/JS, optional CDN <script> tags) works best. " <>
                  "Provide exactly one of `content` or `content_path`."
            },
            "content_path" => %{
              "type" => "string",
              "description" =>
                "Alternative to `content`: a path to a file already on disk (relative to, " <>
                  "or inside, this session's working directory), read directly here on " <>
                  "this session's own node. Use this for content built/tested on disk " <>
                  "across turns instead of Read-ing it into your own context to re-emit " <>
                  "as `content`. Same 50MB cap as put_file. Provide exactly one of " <>
                  "`content` or `content_path`."
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
          "required" => ["name"]
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
            "session). The returned `data` includes the reserved `_user_state` key if " <>
            "the user has ticked/typed anything into a `data-orca-persist` field or " <>
            "called `window.orca.setState` (see save_artifact's description) — read it " <>
            "here to see what the user has persisted, or reset it via " <>
            "update_artifact_data with `data: {\"_user_state\": {}}`.",
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
                  "previous data payload (not a merge) — EXCEPT the reserved " <>
                  "`_user_state` key (see save_artifact's USER STATE section), which is " <>
                  "carried over automatically when you omit it here, so a routine data " <>
                  "refresh doesn't wipe out what the user has persisted. Pass " <>
                  "`_user_state` explicitly (e.g. `{}`) to reset it."
            }
          },
          "required" => ["data"]
        }
      },
      %{
        "name" => "screenshot_artifact",
        "description" =>
          "Collapse the artifact self-preview loop into one call: renders the artifact " <>
            "in a local headless browser on THIS session's own node, sequentially, at " <>
            "each requested viewport width, and saves each screenshot to this session's " <>
            "own media directory — returning file paths for you to Read as images " <>
            "before telling the user the artifact is ready.\n\n" <>
            "Requires a local playwright install on this node; if it isn't available, " <>
            "this returns an error with the fix and the artifact's raw URL so you can " <>
            "drive whatever browser tool IS available yourself.",
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
      },
      %{
        "name" => "attach_artifact_asset",
        "description" =>
          "Attach a file already in the cross-node file store (see put_file) to an " <>
            "artifact as a named asset, so the artifact's own HTML can reference it with " <>
            "a relative URL instead of embedding it inline — useful for images (a " <>
            "chart PNG, a screenshot, a logo) too large or binary to put in `content`. " <>
            "The file must already be visible to this session (put_file/get_file/" <>
            "share_file), and the artifact must belong to this session's project or " <>
            "have been created by this session. Once attached, reference it in the " <>
            "artifact's HTML as <img src=\"assets/<name>\">.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "artifact_id" => %{"type" => "string", "description" => "The artifact's id."},
            "file_id" => %{
              "type" => "string",
              "description" => "The file's id, from put_file/list_files."
            },
            "name" => %{
              "type" => "string",
              "description" =>
                "Asset name, used in the URL as assets/<name>. Defaults to the file's " <>
                  "stored name. Basename-sanitized to a safe URL segment."
            }
          },
          "required" => ["artifact_id", "file_id"]
        }
      }
    ]
  end

  def call("save_artifact", args, state) do
    name = args["name"]
    content = args["content"]
    content_path = args["content_path"]
    kind = normalize_kind(args["kind"])
    open? = Map.get(args, "open", true)
    mode = normalize_mode(args["mode"])

    cond do
      not is_binary(name) or name == "" ->
        error("save_artifact requires a non-empty `name` string argument.")

      present?(content) == present?(content_path) ->
        error("save_artifact requires exactly one of `content` or `content_path`.")

      kind not in @kinds ->
        error("save_artifact `kind` must be one of: #{Enum.join(@kinds, ", ")}.")

      present?(content_path) ->
        do_save_content_path(name, content_path, kind, open?, mode, state)

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
            data: artifact.data,
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

  def call("attach_artifact_asset", args, state) do
    artifact_id = args["artifact_id"]
    file_id = args["file_id"]

    cond do
      not present?(artifact_id) ->
        error("attach_artifact_asset requires a non-empty `artifact_id` string argument.")

      not present?(file_id) ->
        error("attach_artifact_asset requires a non-empty `file_id` string argument.")

      true ->
        do_attach_artifact_asset(artifact_id, file_id, args["name"], state)
    end
  end

  # ── save_artifact ─────────────────────────────────────────────────────

  defp present?(value), do: is_binary(value) and value != ""

  # content_path is confined to the calling session's own directory, just
  # like put_file's `path` (same OrcaHub.PathConfinement invariant), and
  # read HERE on this session's own runner node before the resulting bytes
  # go through the existing HubRPC.save_artifact/1 path unchanged.
  defp do_save_content_path(name, path, kind, open?, mode, state) do
    case resolve_session(state) do
      {:ok, session} -> confine_and_read_content_path(name, path, kind, open?, mode, state, session)
      {:error, message} -> error(message)
    end
  end

  defp resolve_session(state) do
    case state[:orca_session_id] do
      nil ->
        {:error,
         "No OrcaHub session linked to this MCP connection. Cannot resolve `content_path`."}

      session_id ->
        case HubRPC.get_session(session_id) do
          nil -> {:error, "Session #{session_id} not found."}
          session -> {:ok, session}
        end
    end
  end

  defp confine_and_read_content_path(name, path, kind, open?, mode, state, session) do
    case PathConfinement.confine(session.directory, path) do
      {:ok, resolved} ->
        read_content_path(name, path, resolved, kind, open?, mode, state)

      {:error, :outside_root} ->
        error(
          "content_path #{inspect(path)} is outside this session's working directory " <>
            "(after resolving `..` and symlinks)."
        )
    end
  end

  defp read_content_path(name, original_path, resolved, kind, open?, mode, state) do
    case File.stat(resolved) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        if size > Files.max_file_bytes() do
          error(
            "content_path is #{size} bytes, exceeding the #{Files.max_file_bytes()}-byte " <>
              "(50MB) per-file cap."
          )
        else
          content = File.read!(resolved)
          do_save(name, content, kind, open?, mode, state, original_path)
        end

      {:ok, _not_regular} ->
        error("content_path #{inspect(original_path)} is not a regular file.")

      {:error, reason} ->
        error(
          "Could not read content_path #{inspect(original_path)}: " <>
            :file.format_error(reason)
        )
    end
  end

  defp do_save(name, content, kind, open?, mode, state, source \\ nil) do
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
          text(Jason.encode!(save_result(artifact, kind, content, open?, source)))

        {:error, changeset} ->
          error("Failed to save artifact: #{inspect(changeset.errors)}")
      end
    end)
  end

  defp save_result(artifact, "html", content, opened?, source) do
    base_result(artifact, opened?, source)
    |> Map.put(:warnings, HtmlValidator.validate(content))
  end

  defp save_result(artifact, _kind, _content, opened?, source),
    do: base_result(artifact, opened?, source)

  defp base_result(artifact, opened?, source) do
    base = %{
      id: artifact.id,
      name: artifact.name,
      kind: artifact.kind,
      version: artifact.version,
      raw_url: raw_url(artifact),
      opened: opened?
    }

    if source, do: Map.put(base, :content_path, source), else: base
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
  # Renders the artifact's own body (via `OrcaHub.Artifacts.Render`, the
  # exact bytes `/artifacts/:id/raw` serves) to a local temp .html file, then
  # shells out to the playwright CLI once per viewport width to screenshot
  # `file://<that path>` straight into this session's own media directory —
  # no upstream MCP server, no network hop, entirely local to this session's
  # own runner node.

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
  Public and dependency-injectable so tests can exercise the full happy/error
  paths without launching a real browser.

    * `available?` (arity 0) decides whether the playwright CLI is usable on
      this node; defaults to a real `--version` probe.
    * `screenshot_fn` (arity 4, `html_path, width, height, out_path -> :ok |
      {:error, message}`) renders one viewport; defaults to a real
      `playwright screenshot` shell-out.
  """
  def render_screenshots(
        artifact,
        viewports,
        session_id,
        available? \\ &playwright_available?/0,
        screenshot_fn \\ &run_playwright_screenshot/4
      ) do
    if available?.() do
      html_path = write_temp_html(artifact)

      try do
        root = MediaSink.media_root_for(session_id)
        File.mkdir_p!(root)

        screenshots =
          Enum.map(
            viewports,
            &viewport_screenshot(&1, html_path, artifact, root, screenshot_fn)
          )

        text(
          Jason.encode!(%{
            id: artifact.id,
            name: artifact.name,
            raw_url: raw_url(artifact),
            screenshots: screenshots
          })
        )
      after
        File.rm(html_path)
      end
    else
      error(manual_recipe(artifact))
    end
  end

  defp write_temp_html(artifact) do
    path =
      Path.join(
        System.tmp_dir!(),
        "artifact-#{artifact.id}-#{System.unique_integer([:positive])}.html"
      )

    File.write!(path, Render.body(artifact))
    path
  end

  # Sequential by construction — Enum.map/2 over one process, one viewport at
  # a time, matching the tool description's "sequentially" promise.
  defp viewport_screenshot(width, html_path, artifact, root, screenshot_fn) do
    filename = "artifact-#{MediaSink.sanitize_for_filename(artifact.name)}-#{width}px.png"
    out_path = Path.join(root, filename)

    case screenshot_fn.(html_path, width, @default_viewport_height, out_path) do
      :ok -> %{width: width, path: out_path}
      {:error, message} -> %{width: width, error: message}
    end
  end

  defp playwright_cmd, do: Application.get_env(:orca_hub, :playwright_cmd, "npx")

  # `npx` needs `--yes playwright` prepended to resolve/run the CLI; any
  # other configured command (e.g. a global `playwright` binary) is invoked
  # directly with no prefix.
  defp playwright_args(cmd, rest) do
    if Path.basename(cmd) == "npx", do: ["--yes", "playwright" | rest], else: rest
  end

  defp playwright_available? do
    cmd = playwright_cmd()

    if System.find_executable(cmd) do
      case run_bounded(cmd, playwright_args(cmd, ["--version"])) do
        :ok -> true
        {:error, _message} -> false
      end
    else
      false
    end
  end

  defp run_playwright_screenshot(html_path, width, height, out_path) do
    cmd = playwright_cmd()

    if System.find_executable(cmd) do
      args =
        playwright_args(cmd, [
          "screenshot",
          "--viewport-size",
          "#{width},#{height}",
          "file://#{html_path}",
          out_path
        ])

      run_bounded(cmd, args)
    else
      {:error, "playwright command #{inspect(cmd)} not found on PATH"}
    end
  end

  # Runs via a raw Port (not System.cmd/Task) so a timeout can actually kill
  # the external process instead of merely abandoning the BEAM task awaiting
  # it. Erlang already starts a :spawn_executable child as its own process
  # group leader (pid == pgid), so a `kill -9 -<pid>` on timeout takes the
  # whole tree with it (npx -> node -> chromium), not just the immediate
  # child System.cmd would have reaped alone. Public + `@doc false` (not
  # `defp`) purely so the timeout/kill path is directly testable.
  @doc false
  def run_bounded(cmd, args, timeout_ms \\ @screenshot_timeout_ms) do
    case System.find_executable(cmd) do
      nil ->
        {:error, "command #{inspect(cmd)} not found on PATH"}

      path ->
        port =
          Port.open({:spawn_executable, path}, [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            {:args, args}
          ])

        os_pid = Port.info(port)[:os_pid]
        deadline = System.monotonic_time(:millisecond) + timeout_ms
        await_bounded(port, os_pid, deadline, timeout_ms, [])
    end
  rescue
    e -> {:error, "failed to run playwright: #{Exception.message(e)}"}
  end

  defp await_bounded(port, os_pid, deadline, timeout_ms, acc) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        await_bounded(port, os_pid, deadline, timeout_ms, [data | acc])

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, _status}} ->
        {:error, acc |> Enum.reverse() |> IO.iodata_to_binary() |> String.trim()}
    after
      remaining ->
        kill_process_group(os_pid)
        close_port(port)
        {:error, "playwright timed out after #{timeout_ms}ms"}
    end
  end

  defp kill_process_group(nil), do: :ok

  defp kill_process_group(os_pid) do
    System.cmd("kill", ["-9", "-#{os_pid}"], stderr_to_stdout: true)
  rescue
    _ -> :ok
  end

  defp close_port(port) do
    Port.close(port)
  rescue
    _ -> :ok
  end

  defp manual_recipe(artifact) do
    "Playwright isn't available on this node, so screenshot_artifact can't render " <>
      "this artifact locally. Fix: run `npx playwright install chromium` on this " <>
      "node (Node/npx must already be on PATH; set ORCA_PLAYWRIGHT_CMD if this node " <>
      "uses a different playwright command) and retry. In the meantime, drive " <>
      "whatever browser tool IS available yourself against this artifact's raw " <>
      "URL: #{raw_url(artifact)}"
  end

  # ── attach_artifact_asset ─────────────────────────────────────────────

  defp do_attach_artifact_asset(artifact_id, file_id, name, state) do
    with {:ok, session} <- resolve_session(state),
         {:ok, artifact} <- resolve_own_artifact(artifact_id, session),
         {:ok, file} <- resolve_visible_file(file_id, session) do
      asset_name = if present?(name), do: name, else: file.name

      case HubRPC.attach_artifact_asset(artifact, file, asset_name) do
        {:ok, asset} ->
          text(
            "Attached #{file.name} to artifact #{artifact.id} as asset " <>
              "#{inspect(asset.name)}. Reference it in this artifact's HTML as " <>
              "<img src=\"assets/#{asset.name}\">."
          )

        {:error, changeset} ->
          error("Failed to attach asset: #{inspect(changeset_errors(changeset))}")
      end
    else
      {:error, message} -> error(message)
    end
  end

  defp resolve_own_artifact(artifact_id, session) do
    case HubRPC.get_artifact(artifact_id) do
      nil ->
        {:error, "No artifact found with id #{artifact_id}."}

      artifact ->
        if artifact.project_id == session.project_id or artifact.session_id == session.id do
          {:ok, artifact}
        else
          {:error,
           "Artifact #{artifact_id} not found or not accessible to this session " <>
             "(must belong to this session's project or have been created by it)."}
        end
    end
  end

  defp resolve_visible_file(file_id, session) do
    case HubRPC.get_file(file_id) do
      nil ->
        {:error, "File #{inspect(file_id)} not found."}

      file ->
        if HubRPC.file_visible?(file, session.id, session.project_id) do
          {:ok, file}
        else
          {:error, "File #{inspect(file_id)} not found or not visible to this session."}
        end
    end
  end

  defp changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
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
