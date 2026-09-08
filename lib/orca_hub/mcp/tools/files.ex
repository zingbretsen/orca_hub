defmodule OrcaHub.MCP.Tools.Files do
  @moduledoc """
  MCP tools for the cross-node file store (ORCAHUB3-72, see `OrcaHub.Files`
  for the hub-side design/invariants) plus `open_file` (session file
  viewer). `put_file`/`get_file` are the only two that touch the local
  filesystem, and they do so HERE — in the MCP server process, which runs
  in the BEAM on the session's own runner node outside the `run_elixir`
  sandbox (the sandbox never gets `File`). Every byte still crosses
  `OrcaHub.HubRPC` to reach the hub-owned `OrcaHub.Files` context/object
  store; this module never touches S3/object-store credentials directly.
  """

  import OrcaHub.MCP.Tools.Result

  alias OrcaHub.{Cluster, Files, HubRPC, NodePolicy, PathConfinement}

  @orca_inbox ".orca_inbox"

  def list do
    [
      %{
        "name" => "open_file",
        "description" =>
          "Open a file in the user's session file viewer. The file will appear in a side panel next to the chat. Use this to show the user a file you've written or modified, or to pull up a reference file for discussion. Supports relative paths (within the project) and absolute paths (opened read-only if outside the project directory).",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "file_path" => %{
              "type" => "string",
              "description" =>
                "The file path, either relative to the project directory (e.g. \"lib/my_app/module.ex\") or an absolute path (e.g. \"/home/user/other_project/file.ex\", opened read-only if outside project)"
            },
            "line" => %{
              "type" => "integer",
              "description" =>
                "Optional line number to scroll to when opening the file. The file viewer will highlight and scroll to this line."
            }
          },
          "required" => ["file_path"]
        }
      },
      %{
        "name" => "put_file",
        "description" =>
          "Upload a local file into the cross-node file store, so another session (on this " <>
            "node or any other) can pull it in with get_file, or you can share it explicitly " <>
            "with share_file. `path` must resolve inside this session's own working " <>
            "directory (relative paths, or an absolute path inside it) — a `..` escape, an " <>
            "absolute path outside it, or a symlink pointing outside it are all refused. " <>
            "50MB max per file.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "path" => %{
              "type" => "string",
              "description" =>
                "Path to the local file, relative to (or inside) this session's working directory."
            },
            "name" => %{
              "type" => "string",
              "description" => "Stored name for the file. Defaults to the basename of `path`."
            },
            "content_type" => %{
              "type" => "string",
              "description" => "MIME type. Defaults to a guess from the file's extension."
            }
          },
          "required" => ["path"]
        }
      },
      %{
        "name" => "get_file",
        "description" =>
          "Pull a file from the cross-node file store into this session's own working " <>
            "directory, under .orca_inbox/. Visible to you if you created it, it's shared " <>
            "with your project, or it was shared directly with you or your project via " <>
            "share_file. There is no destination argument — the file always lands under " <>
            "your own .orca_inbox/, id-prefixed to avoid collisions.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "file_id" => %{
              "type" => "string",
              "description" => "The file's id, from put_file/list_files."
            }
          },
          "required" => ["file_id"]
        }
      },
      %{
        "name" => "list_files",
        "description" =>
          "List files visible to this session: files you created, files in your project, " <>
            "and files explicitly shared with you or your project.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "project_id" => %{
              "type" => "string",
              "description" =>
                "Optionally narrow the listing to one project's files (still subject to your own visibility)."
            }
          }
        }
      },
      %{
        "name" => "share_file",
        "description" =>
          "Share a file you can already see with another session or an entire project, so " <>
            "get_file/list_files works for the target too. Provide exactly one of " <>
            "session_id or project_id.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "file_id" => %{"type" => "string", "description" => "The file's id."},
            "session_id" => %{"type" => "string", "description" => "Share with this one session."},
            "project_id" => %{
              "type" => "string",
              "description" => "Share with every session in this project."
            }
          },
          "required" => ["file_id"]
        }
      },
      %{
        "name" => "delete_file",
        "description" =>
          "Delete a file from the store (bytes + metadata). Only the creating session or a " <>
            "session in the same project may delete — an explicit share never grants delete " <>
            "rights.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "file_id" => %{"type" => "string", "description" => "The file's id."}
          },
          "required" => ["file_id"]
        }
      }
    ]
  end

  def call("open_file", args, state) do
    file_path = args["file_path"]
    line = args["line"]

    case state.orca_session_id do
      nil ->
        error("No OrcaHub session linked to this MCP connection. Cannot open file in viewer.")

      session_id ->
        Phoenix.PubSub.broadcast(
          OrcaHub.PubSub,
          "session:#{session_id}",
          {:open_file, file_path, line}
        )

        line_msg = if line, do: " at line #{line}", else: ""
        text("Opened #{file_path}#{line_msg} in the session file viewer.")
    end
  end

  def call("put_file", args, state) do
    with_calling_session(state, fn session_id, session ->
      put_file(session_id, session, args)
    end)
  end

  def call("get_file", args, state) do
    with_calling_session(state, fn session_id, session ->
      get_file(session_id, session, args["file_id"])
    end)
  end

  def call("list_files", args, state) do
    with_calling_session(state, fn session_id, session ->
      list_files(session_id, session, args["project_id"])
    end)
  end

  def call("share_file", args, state) do
    with_calling_session(state, fn session_id, session ->
      share_file(session_id, session, args)
    end)
  end

  def call("delete_file", args, state) do
    with_calling_session(state, fn session_id, session ->
      delete_file(session_id, session, args["file_id"])
    end)
  end

  defp with_calling_session(state, fun) do
    case state.orca_session_id do
      nil ->
        error("No OrcaHub session linked to this MCP connection.")

      session_id ->
        case HubRPC.get_session(session_id) do
          nil -> error("Session #{session_id} not found (may have been deleted).")
          session -> fun.(session_id, session)
        end
    end
  end

  # -------------------------------------------------------------------
  # put_file — invariant 1: path is confined by REALPATH before any bytes
  # are read, let alone shipped to the hub.
  # -------------------------------------------------------------------

  defp put_file(session_id, session, args) do
    case PathConfinement.confine(session.directory, args["path"]) do
      {:ok, resolved} ->
        put_confined_file(session_id, session, resolved, args)

      {:error, :outside_root} ->
        error(
          "Path #{inspect(args["path"])} is outside this session's working directory " <>
            "(after resolving `..` and symlinks)."
        )
    end
  end

  defp put_confined_file(session_id, session, resolved, args) do
    case File.stat(resolved) do
      {:ok, %File.Stat{type: :regular, size: size}} ->
        if size > Files.max_file_bytes() do
          error(
            "File is #{size} bytes, exceeding the #{Files.max_file_bytes()}-byte (50MB) " <>
              "per-file cap."
          )
        else
          store_file(session_id, session, resolved, args)
        end

      {:ok, _not_regular} ->
        error("#{inspect(args["path"])} is not a regular file.")

      {:error, reason} ->
        error("Could not read #{inspect(args["path"])}: #{:file.format_error(reason)}")
    end
  end

  defp store_file(session_id, session, resolved, args) do
    name = args["name"] || Path.basename(resolved)
    content_type = args["content_type"] || MIME.from_path(resolved)
    binary = File.read!(resolved)

    attrs = %{
      project_id: session.project_id,
      session_id: session_id,
      name: name,
      content_type: content_type
    }

    case HubRPC.create_file(attrs, binary) do
      {:ok, file} ->
        text(
          "Stored file #{file.id} (#{file.name}, #{file.size_bytes} bytes, sha256 " <>
            "#{file.sha256}). Another session can retrieve it with " <>
            "get_file(file_id: #{inspect(file.id)}); share it with a specific session or " <>
            "project first via share_file if it isn't already visible to them."
        )

      {:error, :too_large} ->
        error("File exceeds the #{Files.max_file_bytes()}-byte (50MB) per-file cap.")

      {:error, :quota_exceeded} ->
        error(
          "This project has exceeded its #{Files.project_quota_bytes()}-byte file store quota."
        )

      {:error, changeset} ->
        error("Failed to store file: #{inspect(changeset_errors(changeset))}")
    end
  end

  # -------------------------------------------------------------------
  # get_file — invariant 2: no destination argument; always writes under
  # the caller's own .orca_inbox/.
  # -------------------------------------------------------------------

  defp get_file(session_id, session, file_id) do
    context = %{session_id: session_id, project_id: session.project_id}

    case HubRPC.fetch_visible_file_binary(file_id, context) do
      {:ok, file, binary} ->
        inbox_dir = Path.join(session.directory, @orca_inbox)
        File.mkdir_p!(inbox_dir)
        dest = Path.join(inbox_dir, "#{String.slice(file.id, 0, 8)}_#{Path.basename(file.name)}")
        File.write!(dest, binary)

        text("Saved #{file.name} (#{file.size_bytes} bytes) to #{dest}.")

      {:error, :not_found} ->
        error("File #{inspect(file_id)} not found or not visible to this session.")

      {:error, reason} ->
        error("Failed to fetch file #{inspect(file_id)}: #{inspect(reason)}")
    end
  end

  # -------------------------------------------------------------------
  # list_files
  # -------------------------------------------------------------------

  defp list_files(session_id, session, filter_project_id) do
    context = %{session_id: session_id, project_id: session.project_id}

    context =
      if filter_project_id,
        do: Map.put(context, :filter_project_id, filter_project_id),
        else: context

    case HubRPC.list_visible_files(context) do
      [] ->
        text("No files visible to this session.")

      files ->
        text(Enum.map_join(files, "\n", &format_file/1))
    end
  end

  defp format_file(file) do
    "#{file.id}  #{file.name}  #{file.size_bytes} bytes  #{file.inserted_at}"
  end

  # -------------------------------------------------------------------
  # share_file — invariant 4: cross-node session target is gated by
  # NodePolicy.cross_node_allowed?/1, checked HERE on the CALLING
  # session's own node.
  # -------------------------------------------------------------------

  defp share_file(session_id, session, args) do
    file_id = args["file_id"]
    target_session_id = args["session_id"]
    target_project_id = args["project_id"]

    cond do
      is_nil(target_session_id) and is_nil(target_project_id) ->
        error("Provide session_id or project_id to share with.")

      not is_nil(target_session_id) and not is_nil(target_project_id) ->
        error("Provide only one of session_id or project_id, not both.")

      true ->
        share_visible_file(session_id, session, file_id, target_session_id, target_project_id)
    end
  end

  defp share_visible_file(session_id, session, file_id, target_session_id, target_project_id) do
    case HubRPC.get_file(file_id) do
      nil ->
        error("File #{inspect(file_id)} not found.")

      file ->
        if HubRPC.file_visible?(file, session_id, session.project_id) do
          share_after_visibility_check(session_id, file, target_session_id, target_project_id)
        else
          error("File #{inspect(file_id)} not found or not visible to this session.")
        end
    end
  end

  defp share_after_visibility_check(session_id, file, target_session_id, nil) do
    do_share(session_id, file, %{session_id: target_session_id})
  end

  defp share_after_visibility_check(session_id, file, nil, target_project_id) do
    do_share(session_id, file, %{project_id: target_project_id})
  end

  defp do_share(session_id, file, %{session_id: target_session_id} = target) do
    case Cluster.find_session(target_session_id) do
      nil ->
        error("Session #{target_session_id} not found on any node.")

      {node, _target_session} ->
        if NodePolicy.cross_node_allowed?(node) do
          persist_share(session_id, file, target)
        else
          error(NodePolicy.denial_message(node))
        end
    end
  end

  defp do_share(session_id, file, %{project_id: _target_project_id} = target) do
    persist_share(session_id, file, target)
  end

  defp persist_share(session_id, file, target) do
    attrs = Map.put(target, :shared_by_session_id, session_id)

    case HubRPC.share_file(file, attrs) do
      {:ok, _share} ->
        text("Shared file #{file.id} (#{file.name}).")

      {:error, changeset} ->
        error("Failed to share file: #{inspect(changeset_errors(changeset))}")
    end
  end

  # -------------------------------------------------------------------
  # delete_file — deletable? (creator or same project) is narrower than
  # visible? (also true for a share target).
  # -------------------------------------------------------------------

  defp delete_file(session_id, session, file_id) do
    case HubRPC.get_file(file_id) do
      nil ->
        error("File #{inspect(file_id)} not found.")

      file ->
        if HubRPC.file_deletable?(file, session_id, session.project_id) do
          {:ok, _} = HubRPC.delete_file(file)
          text("Deleted file #{file_id} (#{file.name}).")
        else
          error(
            "File #{inspect(file_id)} not found or not eligible for deletion by this session."
          )
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
end
