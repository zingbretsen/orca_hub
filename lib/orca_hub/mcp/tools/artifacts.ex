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
  alias OrcaHub.HubRPC
  alias OrcaHub.MCP.CodeExec.MediaSink
  alias OrcaHub.MCP.Tools.Files, as: FilesTool

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
            "IMAGES, VIDEO, AUDIO, FONTS, DATA FILES: never inline them as base64 or " <>
            "`data:` URIs. That bloats every save and burns your own context. Pass them as " <>
            "`assets` instead: an object mapping asset name -> local file path (same " <>
            "working-directory confinement and 50MB per-file cap as `content_path`), " <>
            "uploaded and attached in this same call. Reference each one by its RELATIVE " <>
            "URL: <img src=\"assets/chart.png\">, <video src=\"assets/clip.mp4\" controls " <>
            "playsinline>, <audio src=\"assets/a.mp3\" controls>, CSS " <>
            "url(assets/font.woff2), fetch(\"assets/data.json\") (works from the sandbox: " <>
            "asset responses send CORS headers). Re-saving with an asset name that's " <>
            "already attached REPLACES it (identical bytes are detected and not " <>
            "re-uploaded); assets you don't mention stay attached. The result lists every " <>
            "attached asset's `ref` and a signed absolute `url` you can WebFetch to check " <>
            "it. That url is a capability: anyone holding it can read this artifact and " <>
            "its assets, without logging in, for about a day. Share it deliberately, and " <>
            "re-save or re-attach for a fresh one rather than storing it. NOT possible " <>
            "from the sandbox: downloads (the iframe has no " <>
            "allow-downloads, and <a download> is ignored there, so the link just " <>
            "navigates the artifact's own frame to the file, replacing the artifact; a " <>
            "plain link to an asset does the same), new tabs/windows " <>
            "(target=\"_blank\" and window.open are blocked, no allow-popups), and PDFs " <>
            "(an <iframe>/<embed>/<object> PDF renders as blocked). If the user needs the " <>
            "file itself, give them its `url` in chat.\n\n" <>
            "Saving under a `name` that already exists in this project UPDATES that " <>
            "artifact in place (and bumps its version) rather than creating a new one — " <>
            "reuse the same name to iterate on one artifact across turns/sessions.\n\n" <>
            "LIVE DATA: an artifact carries a `data` snapshot (a JSON object). Seed it in " <>
            "this same call with the `data` argument, no separate update_artifact_data call " <>
            "needed. A re-save with `data` replaces the stored snapshot; one without it " <>
            "keeps it. If the numbers change later (a dashboard, a report, a live counter), " <>
            "don't re-save the whole document to refresh them — call update_artifact_data " <>
            "instead, which pushes a new `data` snapshot into the SAME artifact without " <>
            "reloading/rewriting its HTML. Your HTML must read `window.ORCA_DATA` on load " <>
            "for the initial snapshot, and listen for live updates with " <>
            "`window.addEventListener(\"message\", (e) => { if (e.data?.type " <>
            "=== \"orca:data\") /* e.data.data is the new snapshot */ })`. The iframe's " <>
            "sandbox has an opaque origin (no `allow-same-origin`), so `fetch()` from " <>
            "inside it can't reach this host's app or API. Apart from reading the " <>
            "artifact's own `assets/`, ORCA_DATA/postMessage is the only data path in or " <>
            "out.\n\n" <>
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
            "`data-orca-persist=\"some-key\"`. It's restored on load (checkbox -> " <>
            "checked; radio -> give every radio in a group the SAME key and a distinct " <>
            "`value`, the key stores the selected value; everything else -> value) " <>
            "and written through automatically " <>
            "(`change` immediately, `input` debounced ~300ms). For anything the " <>
            "declarative attribute can't express, call `window.orca.setState(patch)` " <>
            "with a flat JSON object yourself (shallow-merged into storage — existing " <>
            "keys not in `patch` are left alone; a key set to `null` deletes it) and " <>
            "`window.orca.getState()` to read the current state back synchronously. " <>
            "State lives under the reserved `_user_state` key in this artifact's `data` " <>
            "(visible via get_artifact) and survives re-saving this artifact (save_artifact " <>
            "never writes it, even with `data`), but is lost if you rename it (a rename " <>
            "is a different artifact row). It's " <>
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
            "assets" => %{
              "type" => "object",
              "additionalProperties" => %{"type" => "string"},
              "description" =>
                "Optional files to attach in this same call, as an object mapping asset " <>
                  "name -> local file path, e.g. {\"chart.png\": \"out/chart.png\", " <>
                  "\"clip.mp4\": \"/abs/path/inside/workdir/clip.mp4\"}. Each name is the " <>
                  "URL segment the content references as assets/<name> (letters, digits, " <>
                  "`.`, `_`, `-` only). Paths follow `content_path`'s rules. Everything is " <>
                  "checked before anything is saved. An existing name is replaced; names " <>
                  "not listed stay attached."
            },
            "data" => %{
              "type" => "object",
              "description" =>
                "Optional live-data snapshot, a JSON object, served to the page as " <>
                  "`window.ORCA_DATA`. Seeds a new artifact's data; on an existing one it " <>
                  "REPLACES the stored snapshot, like update_artifact_data. Omit it to keep " <>
                  "the stored data. save_artifact never writes the reserved `_user_state` " <>
                  "key: the stored user state is kept, and a `_user_state` key here is " <>
                  "ignored with a warning."
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
            "document (the first snapshot can ride save_artifact's own `data` argument). " <>
            "Does not bump the artifact's version. Delivered to any already-open " <>
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
            "before telling the user the artifact is ready. Attached assets are written " <>
            "next to the rendered document, so relative assets/<name> images, CSS " <>
            "backgrounds, stylesheets and fonts show up. fetch() of an asset does NOT work " <>
            "here (the render is a local file:// page), so check fetch-driven content " <>
            "by WebFetch-ing the asset `url` instead.\n\n" <>
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
          "Attach ONE file to an already-saved artifact as a named asset, so its content " <>
            "references it by a relative URL (assets/<name>) instead of inlining it as " <>
            "base64. When you're saving the content anyway, save_artifact's `assets` " <>
            "argument does this in the same call. Give exactly one source: `path` (a " <>
            "local file, confined to this session's working directory like put_file, " <>
            "uploaded in this call) or `file_id` (a file already in the store and visible " <>
            "to this session via put_file/get_file/share_file). The artifact must belong " <>
            "to this session's project or have been created by this session. Attaching " <>
            "under a name that's already attached replaces it. The result gives the " <>
            "asset's `ref` for the content (e.g. <img src=\"assets/<name>\">) and a signed " <>
            "absolute `url` you can WebFetch to check it.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "artifact_id" => %{"type" => "string", "description" => "The artifact's id."},
            "path" => %{
              "type" => "string",
              "description" =>
                "A local file to upload and attach, relative to (or inside) this " <>
                  "session's working directory. 50MB max. Alternative to `file_id`."
            },
            "file_id" => %{
              "type" => "string",
              "description" =>
                "The id of a file already in the store, from put_file/list_files. " <>
                  "Alternative to `path`."
            },
            "name" => %{
              "type" => "string",
              "description" =>
                "Asset name, used in the URL as assets/<name>. Defaults to the basename " <>
                  "of `path`, or the stored file's name. Basename-sanitized to a safe URL " <>
                  "segment (only letters, digits, `.`, `_`, `-` survive)."
            }
          },
          "required" => ["artifact_id"]
        }
      }
    ]
  end

  # Any argument that isn't a property of the tool's own inputSchema (from
  # list/0, the one source of truth) would otherwise be dropped silently, and
  # a misspelling (`contents`, `contentPath`) is often why a call failed. So
  # every result names them: a `warnings` entry on success, a note appended
  # to the message on error (ORCAHUB3-132).
  def call(tool, args, state) do
    tool
    |> run(args, state)
    |> note_unknown_args(tool, unknown_args(tool, args))
  end

  defp run("save_artifact", args, state) do
    kind = normalize_kind(args["kind"])
    open? = Map.get(args, "open", true)
    mode = normalize_mode(args["mode"])

    with :ok <- validate_save_args(args, kind),
         {:ok, session} <- resolve_project_session(state),
         {:ok, specs} <- confine_assets(args["assets"], session),
         {:ok, content, source} <- load_content(args, session) do
      do_save(session, %{
        name: args["name"],
        kind: kind,
        content: content,
        data: args["data"],
        source: source,
        specs: specs,
        open?: open?,
        mode: mode
      })
    else
      {:error, message} -> error(message)
    end
  end

  defp run("open_artifact", args, state) do
    mode = normalize_mode(args["mode"])

    case resolve_artifact(args, state) do
      {:ok, artifact} -> do_open(artifact, mode, state)
      {:error, message} -> error(message)
    end
  end

  defp run("list_artifacts", _args, state) do
    with_project(state, fn project_id ->
      artifacts =
        project_id
        |> HubRPC.list_artifacts_for_project()
        |> Enum.map(&summary/1)

      text(Jason.encode!(%{"count" => length(artifacts), "artifacts" => artifacts}))
    end)
  end

  defp run("get_artifact", args, state) do
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

  defp run("update_artifact_data", args, state) do
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

  defp run("screenshot_artifact", args, state) do
    viewports = normalize_viewports(args["viewports"])

    case resolve_artifact(args, state) do
      {:ok, artifact} -> do_screenshot(artifact, viewports, state)
      {:error, message} -> error(message)
    end
  end

  defp run("attach_artifact_asset", args, state) do
    cond do
      not present?(args["artifact_id"]) ->
        error("attach_artifact_asset requires a non-empty `artifact_id` string argument.")

      present?(args["path"]) == present?(args["file_id"]) ->
        error(
          "attach_artifact_asset requires exactly one of `path` (a local file, uploaded " <>
            "in this call) or `file_id` (a file already in the store)."
        )

      true ->
        do_attach_artifact_asset(args, state)
    end
  end

  # ── unknown arguments ─────────────────────────────────────────────────

  defp unknown_args(tool, args) when is_map(args) do
    known = schema_properties(tool)
    args |> Map.keys() |> Enum.reject(&Map.has_key?(known, &1)) |> Enum.sort()
  end

  defp unknown_args(_tool, _args), do: []

  defp schema_properties(tool) do
    case Enum.find(list(), &(&1["name"] == tool)) do
      %{"inputSchema" => %{"properties" => properties}} -> properties
      _ -> %{}
    end
  end

  defp note_unknown_args(result, _tool, []), do: result

  defp note_unknown_args(%{"content" => [%{"text" => text} = part]} = result, tool, unknown) do
    note = unknown_args_note(tool, unknown)

    text =
      case {result["isError"], Jason.decode(text)} do
        {true, _} ->
          text <> " " <> note

        {_, {:ok, %{} = body}} ->
          body |> Map.update("warnings", [note], &[note | &1]) |> Jason.encode!()

        _ ->
          text
      end

    %{result | "content" => [%{part | "text" => text}]}
  end

  defp note_unknown_args(result, _tool, _unknown), do: result

  defp unknown_args_note(tool, unknown) do
    names = Enum.map_join(unknown, ", ", &arg_label/1)
    known = tool |> schema_properties() |> Map.keys() |> Enum.sort()

    takes =
      if known == [],
        do: "#{tool} takes no arguments.",
        else: "#{tool} takes: #{Enum.map_join(known, ", ", &arg_label/1)}."

    "Ignored unknown argument#{if length(unknown) > 1, do: "s"} #{names}. #{takes}"
  end

  defp arg_label(name) when is_binary(name), do: "`#{name}`"
  defp arg_label(name), do: inspect(name)

  # ── save_artifact ─────────────────────────────────────────────────────
  #
  # Every check that can fail runs BEFORE anything is persisted: the args,
  # the session/project, and each asset's and content_path's confinement,
  # stat and size cap. Only then are asset bytes uploaded (any already
  # uploaded are deleted again if a later one fails), and only then is the
  # artifact saved and the uploads attached. Local paths are read HERE, on
  # this session's own runner node, through put_file's own helpers
  # (`MCP.Tools.Files.confine_local_file/3`, `upload_local_file/4`); the
  # bytes reach the hub-owned store over HubRPC.

  defp present?(value), do: is_binary(value) and value != ""

  defp validate_save_args(args, kind) do
    cond do
      not present?(args["name"]) ->
        {:error, "save_artifact requires a non-empty `name` string argument."}

      present?(args["content"]) == present?(args["content_path"]) ->
        {:error, "save_artifact requires exactly one of `content` or `content_path`."}

      kind not in @kinds ->
        {:error, "save_artifact `kind` must be one of: #{Enum.join(@kinds, ", ")}."}

      not (is_nil(args["data"]) or is_map(args["data"])) ->
        {:error, "save_artifact `data` must be a JSON object. Nothing was saved."}

      true ->
        validate_assets_arg(args["assets"])
    end
  end

  defp validate_assets_arg(nil), do: :ok

  defp validate_assets_arg(assets) when is_map(assets) do
    Enum.find_value(assets, :ok, fn {name, path} ->
      cond do
        not safe_asset_name?(name) ->
          {:error,
           "save_artifact `assets`: #{inspect(name)} is not a usable asset name. " <>
             asset_name_hint(name)}

        not present?(path) ->
          {:error,
           "save_artifact `assets`: #{inspect(name)} must map to a local file path string."}

        true ->
          nil
      end
    end)
  end

  defp validate_assets_arg(_assets) do
    {:error, "save_artifact `assets` must be an object mapping asset name -> local file path."}
  end

  # `OrcaHub.Artifacts.attach_asset/3` silently rewrites a name to
  # `[A-Za-z0-9._-]`. An `assets` key is refused instead of rewritten,
  # because the content saved in the same call already references it
  # verbatim, and a rewritten name would leave that reference dangling.
  defp safe_asset_name?(name) when is_binary(name),
    do: name =~ ~r/\A[A-Za-z0-9._-]+\z/ and name not in [".", ".."]

  defp safe_asset_name?(_name), do: false

  defp sanitize_asset_name(name) do
    name
    |> Path.basename()
    |> String.replace(~r/[^A-Za-z0-9._-]/, "_")
  end

  defp asset_name_hint(name) do
    rule = "A name is one URL segment: letters, digits, `.`, `_`, `-`, no directories."
    suggestion = if is_binary(name), do: sanitize_asset_name(name)

    if safe_asset_name?(suggestion), do: rule <> " Try #{inspect(suggestion)}.", else: rule
  end

  defp confine_assets(nil, _session), do: {:ok, []}

  defp confine_assets(assets, session) do
    assets
    |> Enum.sort()
    |> Enum.reduce_while({:ok, []}, fn {name, path}, {:ok, specs} ->
      label = "assets[#{inspect(name)}]"

      case FilesTool.confine_local_file(session.directory, path, label) do
        {:ok, resolved, size} ->
          spec = %{name: name, path: path, resolved: resolved, size: size}
          {:cont, {:ok, [spec | specs]}}

        {:error, message} ->
          {:halt, {:error, "save_artifact: #{message} Nothing was saved."}}
      end
    end)
    |> case do
      {:ok, specs} -> {:ok, Enum.reverse(specs)}
      error -> error
    end
  end

  defp load_content(%{"content_path" => path}, session) when is_binary(path) and path != "" do
    with {:ok, resolved, _size} <-
           FilesTool.confine_local_file(session.directory, path, "content_path") do
      {:ok, File.read!(resolved), path}
    end
  end

  defp load_content(args, _session), do: {:ok, args["content"], nil}

  defp do_save(session, save) do
    existing =
      if save.specs != [], do: HubRPC.get_artifact_by_name(session.project_id, save.name)

    with {:ok, staged} <- stage_assets(save.specs, existing, session),
         {:ok, artifact} <- persist_artifact(session, save, existing, staged) do
      if save.open?, do: broadcast_open(session.id, artifact.id, save.mode)
      text(Jason.encode!(save_result(artifact, save, staged)))
    else
      {:error, message} -> error(message)
    end
  end

  # Uploads every asset before the artifact is touched, reusing the file
  # already attached under a name when the bytes are identical (so
  # re-saving an artifact to iterate on its HTML doesn't re-upload, or
  # re-count against the project quota, every image it uses).
  defp stage_assets(specs, existing, session) do
    specs
    |> Enum.reduce_while({:ok, []}, fn spec, {:ok, staged} ->
      case stage_asset(spec, existing, session) do
        {:ok, item} ->
          {:cont, {:ok, [item | staged]}}

        {:error, message} ->
          discard_uploads(staged)

          {:halt,
           {:error, "save_artifact assets[#{inspect(spec.name)}]: #{message} Nothing was saved."}}
      end
    end)
    |> case do
      {:ok, staged} -> {:ok, Enum.reverse(staged)}
      error -> error
    end
  end

  defp stage_asset(spec, existing, session) do
    content_type = asset_content_type(spec.name, spec.resolved)
    current = attached_file(existing, spec.name)

    if unchanged?(current, spec, content_type) do
      {:ok, Map.merge(spec, %{file: current, uploaded?: false})}
    else
      with {:ok, file} <-
             FilesTool.upload_local_file(session, spec.resolved, spec.name, content_type) do
        {:ok, Map.merge(spec, %{file: file, uploaded?: true})}
      end
    end
  end

  # The browser fetches an asset by its NAME (assets/<name>), so the name's
  # extension picks the Content-Type; the local path's is the fallback.
  defp asset_content_type(name, resolved) do
    case MIME.from_path(name) do
      "application/octet-stream" -> MIME.from_path(resolved)
      type -> type
    end
  end

  defp attached_file(nil, _name), do: nil

  defp attached_file(artifact, name) do
    case HubRPC.get_artifact_asset(artifact.id, name) do
      %{file: %{} = file} -> file
      _ -> nil
    end
  end

  defp unchanged?(nil, _spec, _content_type), do: false

  defp unchanged?(file, spec, content_type) do
    file.size_bytes == spec.size and file.content_type == content_type and
      file.sha256 == file_sha256(spec.resolved)
  end

  defp file_sha256(path) do
    path
    |> File.stream!(2_097_152)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end

  defp discard_uploads(staged) do
    for %{uploaded?: true, file: file} <- staged, do: HubRPC.delete_file(file)
    :ok
  end

  # An existing artifact gets its new assets BEFORE its new content: the
  # save's version bump is what reloads open viewers, so every new ref
  # already resolves by then. A new artifact has no viewer until the open
  # broadcast, which do_save/2 sends only after the attach.
  defp persist_artifact(session, save, nil, staged) do
    with {:ok, artifact} <- save_content(session, save, staged) do
      case attach_staged(artifact, staged) do
        :ok ->
          {:ok, artifact}

        {:error, message} ->
          {:error,
           message <>
             " The artifact itself was saved (version #{artifact.version}); attach the " <>
             "missing assets with attach_artifact_asset."}
      end
    end
  end

  defp persist_artifact(session, save, existing, staged) do
    case attach_staged(existing, staged) do
      :ok -> save_content(session, save, [])
      {:error, message} -> {:error, message <> " The new content was NOT saved."}
    end
  end

  defp save_content(session, save, staged) do
    attrs = %{
      project_id: session.project_id,
      session_id: session.id,
      name: save.name,
      kind: save.kind,
      content: save.content
    }

    # Without `data` the stored data is left alone. With it, the hub drops
    # any `_user_state` here and keeps the row's own (Artifacts.save_artifact/1).
    case attrs |> maybe_put(:data, save.data) |> HubRPC.save_artifact() do
      {:ok, artifact} ->
        {:ok, artifact}

      {:error, changeset} ->
        discard_uploads(staged)
        {:error, "Failed to save artifact: #{inspect(changeset.errors)}"}
    end
  end

  defp attach_staged(artifact, staged) do
    staged
    |> Enum.filter(& &1.uploaded?)
    |> attach_each(artifact)
  end

  defp attach_each([], _artifact), do: :ok

  defp attach_each([item | rest] = pending, artifact) do
    case HubRPC.attach_artifact_asset(artifact, item.file, item.name) do
      {:ok, _asset} ->
        attach_each(rest, artifact)

      {:error, changeset} ->
        discard_uploads(pending)

        {:error,
         "Attaching asset #{inspect(item.name)} to artifact #{artifact.id} failed " <>
           "(#{inspect(changeset_errors(changeset))}); it and any assets after it were " <>
           "not attached."}
    end
  end

  defp save_result(artifact, save, staged) do
    attached = artifact |> HubRPC.list_artifact_assets() |> Enum.map(& &1.name)
    urls = HubRPC.artifact_urls(artifact, attached)

    %{
      id: artifact.id,
      name: artifact.name,
      kind: artifact.kind,
      version: artifact.version,
      raw_url: urls.raw_url,
      opened: save.open?
    }
    |> maybe_put(:content_path, save.source)
    |> maybe_put(:assets, asset_entries(attached, urls.asset_urls, staged))
    |> put_warnings(save, attached)
  end

  # Every asset attached after this save, not just the ones in this call,
  # so the result is the complete list of refs the content can use. Ones
  # from this call also say where they came from and whether the bytes
  # were already attached (`unchanged`, no upload).
  defp asset_entries([], _urls, _staged), do: nil

  defp asset_entries(attached, urls, staged) do
    by_name = Map.new(staged, &{&1.name, &1})

    Enum.map(attached, fn name ->
      entry = asset_entry(name, Map.fetch!(urls, name))

      case by_name do
        %{^name => item} ->
          Map.merge(entry, %{path: item.path, size_bytes: item.size, unchanged: !item.uploaded?})

        _ ->
          entry
      end
    end)
  end

  defp put_warnings(result, %{kind: "html", content: content} = save, attached) do
    Map.put(
      result,
      :warnings,
      HtmlValidator.validate(content) ++ save_warnings(save, attached)
    )
  end

  defp put_warnings(result, save, attached) do
    case save_warnings(save, attached) do
      [] -> result
      warnings -> Map.put(result, :warnings, warnings)
    end
  end

  defp save_warnings(save, attached) do
    user_state_warnings(save.data) ++ content_warnings(save.content, attached)
  end

  defp user_state_warnings(%{"_user_state" => _}) do
    [
      "Ignored `data._user_state`: save_artifact never writes user state, the stored " <>
        "one is kept. To reset it, call update_artifact_data with " <>
        "`data: {\"_user_state\": {}}`."
    ]
  end

  defp user_state_warnings(_data), do: []

  # Non-fatal lint for the two asset mistakes an agent can't see from the
  # result alone: inlined base64 media (what `assets` exists to replace)
  # and a reference to an asset name that isn't attached (a typo, or an
  # attach still to come).
  @inline_base64 ~r/data:[\w.+-]+\/[\w.+-]+;base64,[A-Za-z0-9+\/=]{2048}/
  @asset_ref ~r/(?:^|["'(=\s])(?:\.\/)?assets\/([A-Za-z0-9._-]+)/m

  defp content_warnings(content, attached) do
    inline_base64_warnings(content) ++ missing_asset_warnings(content, attached)
  end

  defp inline_base64_warnings(content) do
    case @inline_base64 |> Regex.scan(content) |> length() do
      0 ->
        []

      count ->
        [
          "Inlines #{count} base64 data: URI(s) of 2KB or more. Pass images, video, " <>
            "audio, fonts and data files as save_artifact `assets` (name -> local path) " <>
            "and reference them as assets/<name> instead."
        ]
    end
  end

  defp missing_asset_warnings(content, attached) do
    @asset_ref
    |> Regex.scan(content, capture: :all_but_first)
    |> Enum.map(fn [name] -> String.trim_trailing(name, ".") end)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "" or &1 in attached))
    |> Enum.map(
      &"References assets/#{&1}, but no asset named #{inspect(&1)} is attached to this artifact."
    )
  end

  # `ref` is what the content uses; `url` is the signed absolute capability
  # URL (`OrcaHubWeb.ArtifactURL`, minted on the hub) an agent can WebFetch
  # to check the asset is really served.
  defp asset_entry(name, url) do
    %{name: name, ref: "assets/#{name}", url: url, usage: asset_usage(name)}
  end

  defp asset_usage(name) do
    ref = "assets/#{name}"

    case MIME.from_path(name) do
      "image/" <> _ -> ~s(<img src="#{ref}">)
      "video/" <> _ -> ~s(<video src="#{ref}" controls playsinline></video>)
      "audio/" <> _ -> ~s(<audio src="#{ref}" controls></audio>)
      "font/" <> _ -> ~s[@font-face { font-family: X; src: url(#{ref}); }]
      "text/css" -> ~s(<link rel="stylesheet" href="#{ref}">)
      "text/javascript" -> ~s(<script src="#{ref}"></script>)
      "application/javascript" -> ~s(<script src="#{ref}"></script>)
      _ -> ~s[fetch("#{ref}")]
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # ── open_artifact ─────────────────────────────────────────────────────

  defp do_open(artifact, mode, state) do
    broadcast_open(state[:orca_session_id], artifact.id, mode)

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

  defp broadcast_open(nil, _artifact_id, _mode), do: :ok

  defp broadcast_open(session_id, artifact_id, mode) do
    Phoenix.PubSub.broadcast(
      OrcaHub.PubSub,
      "session:#{session_id}",
      {:open_artifact, artifact_id, mode}
    )
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
  # exact bytes `/artifacts/:id/raw` serves) into a temp DIRECTORY as
  # index.html, with every attached asset written beside it at
  # assets/<name> (bytes fetched over HubRPC exactly as the asset route
  # fetches them), so the body's relative assets/<name> refs resolve
  # against file://. Then shells out to the playwright CLI once per
  # viewport width to screenshot `file://<dir>/index.html` straight into
  # this session's own media directory: no upstream MCP server, no network
  # hop, entirely local to this session's own runner node. The whole
  # directory is removed afterwards.

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
      `playwright screenshot` shell-out. `html_path` is the temp render
      directory's `index.html`, with the artifact's assets under
      `assets/` next to it.
  """
  def render_screenshots(
        artifact,
        viewports,
        session_id,
        available? \\ &playwright_available?/0,
        screenshot_fn \\ &run_playwright_screenshot/4
      ) do
    if available?.() do
      dir =
        Path.join(
          System.tmp_dir!(),
          "artifact-#{artifact.id}-#{System.unique_integer([:positive])}"
        )

      try do
        {html_path, missing} = write_render_dir(dir, artifact)
        root = MediaSink.media_root_for(session_id)
        File.mkdir_p!(root)

        screenshots =
          Enum.map(
            viewports,
            &viewport_screenshot(&1, html_path, artifact, root, screenshot_fn)
          )

        %{
          id: artifact.id,
          name: artifact.name,
          raw_url: raw_url(artifact),
          screenshots: screenshots
        }
        |> maybe_put(:missing_assets, if(missing != [], do: missing))
        |> Jason.encode!()
        |> text()
      after
        File.rm_rf(dir)
      end
    else
      error(manual_recipe(artifact))
    end
  end

  # Returns the index.html path and the names of any attached assets whose
  # bytes couldn't be fetched (they render broken, as they would live).
  defp write_render_dir(dir, artifact) do
    assets_dir = Path.join(dir, "assets")
    File.mkdir_p!(assets_dir)
    html_path = Path.join(dir, "index.html")
    File.write!(html_path, Render.body(artifact))

    missing =
      artifact
      |> HubRPC.list_artifact_assets()
      |> Enum.map(& &1.name)
      |> Enum.reject(&write_render_asset(assets_dir, artifact, &1))

    {html_path, missing}
  end

  defp write_render_asset(assets_dir, artifact, name) do
    with true <- safe_asset_name?(name),
         %{file: %{} = file} <- HubRPC.get_artifact_asset(artifact.id, name),
         {:ok, binary} <- HubRPC.fetch_file_binary(file) do
      File.write!(Path.join(assets_dir, name), binary)
      true
    else
      _ -> false
    end
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

  defp do_attach_artifact_asset(args, state) do
    with {:ok, session} <- resolve_session(state),
         {:ok, artifact} <- resolve_own_artifact(args["artifact_id"], session),
         {:ok, source} <- resolve_asset_source(args, session),
         {:ok, name} <- attach_asset_name(args["name"], source),
         {:ok, file} <- source_file(source, name, session) do
      case HubRPC.attach_artifact_asset(artifact, file, name) do
        {:ok, asset} ->
          text(Jason.encode!(attach_result(artifact, asset, file, source)))

        {:error, changeset} ->
          if source.kind == :path, do: HubRPC.delete_file(file)
          error("Failed to attach asset: #{inspect(changeset_errors(changeset))}")
      end
    else
      {:error, message} -> error(message)
    end
  end

  defp resolve_session(state) do
    case state[:orca_session_id] do
      nil ->
        {:error, "No OrcaHub session linked to this MCP connection."}

      session_id ->
        case HubRPC.get_session(session_id) do
          nil -> {:error, "Session #{session_id} not found."}
          session -> {:ok, session}
        end
    end
  end

  # A `path` is only confined and stat'ed here; it is uploaded by
  # source_file/3 once the asset name is known to be usable, so a refused
  # call never leaves an orphan file in the store.
  defp resolve_asset_source(%{"path" => path}, session) when is_binary(path) and path != "" do
    with {:ok, resolved, size} <- FilesTool.confine_local_file(session.directory, path, "path") do
      {:ok, %{kind: :path, path: path, resolved: resolved, size: size}}
    end
  end

  defp resolve_asset_source(%{"file_id" => file_id}, session) do
    with {:ok, file} <- resolve_visible_file(file_id, session) do
      {:ok, %{kind: :file, file: file}}
    end
  end

  defp attach_asset_name(name, source) do
    requested = if present?(name), do: name, else: default_asset_name(source)
    sanitized = sanitize_asset_name(requested)

    if safe_asset_name?(sanitized) do
      {:ok, sanitized}
    else
      {:error,
       "Asset name #{inspect(requested)} has no usable characters; pass a `name` made " <>
         "of letters, digits, `.`, `_`, `-`."}
    end
  end

  defp default_asset_name(%{kind: :path, path: path}), do: Path.basename(path)
  defp default_asset_name(%{kind: :file, file: file}), do: file.name || ""

  defp source_file(%{kind: :file, file: file}, _name, _session), do: {:ok, file}

  defp source_file(%{kind: :path, resolved: resolved}, name, session) do
    FilesTool.upload_local_file(session, resolved, name, asset_content_type(name, resolved))
  end

  defp attach_result(artifact, asset, file, source) do
    asset.name
    |> asset_entry(HubRPC.artifact_asset_url(artifact.id, asset.name))
    |> Map.merge(%{artifact_id: artifact.id, file_id: file.id, size_bytes: file.size_bytes})
    |> maybe_put(:path, source[:path])
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
    with {:ok, session} <- resolve_project_session(state), do: {:ok, session.project_id}
  end

  defp resolve_project_session(state) do
    case state[:orca_session_id] do
      nil ->
        {:error, "No OrcaHub session linked to this MCP connection. Cannot resolve a project."}

      session_id ->
        case HubRPC.get_session(session_id) do
          nil -> {:error, "Session #{session_id} not found."}
          %{project_id: nil} -> {:error, "This session has no associated project."}
          session -> {:ok, session}
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

  # The signed absolute capability URL (`OrcaHubWeb.ArtifactURL`), minted on
  # the hub: the one URL an agent can actually fetch, since the old
  # /artifacts/:id/raw sits behind Authelia.
  defp raw_url(artifact), do: HubRPC.artifact_raw_url(artifact)
end
