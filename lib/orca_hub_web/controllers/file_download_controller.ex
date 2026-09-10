defmodule OrcaHubWeb.FileDownloadController do
  @moduledoc """
  Streams a single file out of a project's or session's working directory,
  on whichever node actually owns that directory, so a file panel row
  (`OrcaHubWeb.FileTreeComponent`, ORCAHUB3-76) can be downloaded from the
  browser.

  Two routes, not one shared `/projects/:id/...` route: the session file
  panel is passed a SYNTHETIC, unpersisted `%OrcaHub.Projects.Project{}`
  (see `session_live/show.html.heex`) that has no id, so a project-id-keyed
  route can't serve it. Each action resolves its own trusted root
  (`directory`) and target node SERVER-SIDE from the `:id` in the path —
  `path` is the only client-supplied input, confined with
  `OrcaHub.PathConfinement` on the OWNING node (confinement is
  realpath-based and needs the real filesystem underneath it, so it cannot
  run here on the hub if the hub isn't the owning node).

  Bytes are read in bounded chunks and `Plug.Conn.chunk/2`'d out, one
  `Cluster.rpc` per chunk, deliberately never loading a whole file into one
  erpc reply: a single big distribution message would head-of-line-block
  everything else sharing that node pair's one Erlang distribution
  connection (PubSub, HubRPC DB calls, heartbeats). Deliberately not routed
  through `OrcaHub.Files`/MinIO either — the object store is hub-only, so
  that would ship the bytes over the SAME distribution link first and then
  add an S3 write, an S3 read, and a durable copy nobody asked for.
  """
  use OrcaHubWeb, :controller

  alias OrcaHub.{Cluster, HubRPC, PathConfinement}

  # Upper bound on a single download — comfortably above any working-
  # directory artifact we expect (screenshots, PDFs, small archives), far
  # below something that would tie up a chunked response indefinitely.
  @max_bytes 200 * 1024 * 1024
  @chunk_bytes 1024 * 1024

  def project(conn, %{"id" => id} = params) do
    case HubRPC.get_project(id) do
      nil ->
        not_found(conn)

      project ->
        stream_download(conn, Cluster.project_node_for(project), project.directory, params)
    end
  end

  def session(conn, %{"id" => id} = params) do
    case HubRPC.get_session(id) do
      nil ->
        not_found(conn)

      session ->
        stream_download(conn, Cluster.runner_node_for(session), session.directory, params)
    end
  end

  defp stream_download(conn, node, root, %{"path" => path}) when is_binary(path) do
    case Cluster.rpc(node, __MODULE__, :stat_confined, [root, path]) do
      {:ok, resolved, size} -> send_file_chunks(conn, node, resolved, size, path)
      {:error, reason} -> error_response(conn, reason)
    end
  end

  defp stream_download(conn, _node, _root, _params),
    do: bad_request(conn, "Missing path parameter")

  # Exported (not just private) because `Cluster.rpc/5` invokes this ON THE
  # OWNING NODE via :erpc — `PathConfinement.confine/2` is realpath-based
  # and needs the real filesystem underneath it. Rejects anything that
  # isn't a regular file (a directory, socket, device, or broken symlink)
  # and anything over `@max_bytes`.
  @doc false
  def stat_confined(root, path) do
    with {:ok, resolved} <- PathConfinement.confine(root, path),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(resolved) do
      if size > @max_bytes, do: {:error, :too_large}, else: {:ok, resolved, size}
    else
      {:ok, %File.Stat{}} -> {:error, :not_a_file}
      {:error, :outside_root} -> {:error, :outside_root}
      {:error, _posix} -> {:error, :not_found}
    end
  end

  # Exported for the same reason as stat_confined/2 above. A stateless,
  # single-chunk read (open, pread, close) rather than holding a file
  # handle open across erpc calls — that handle would be owned by a
  # transient process on the remote node and couldn't outlive the call.
  @doc false
  def read_chunk(path, offset, size) do
    case File.open(path, [:read, :binary]) do
      {:ok, file} ->
        result =
          case :file.pread(file, offset, size) do
            {:ok, data} -> {:ok, data}
            :eof -> {:ok, ""}
            {:error, reason} -> {:error, reason}
          end

        File.close(file)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp send_file_chunks(conn, node, resolved_path, size, requested_path) do
    conn =
      conn
      |> put_resp_content_type(MIME.from_path(requested_path))
      |> put_resp_header(
        "content-disposition",
        "attachment; filename=\"#{download_filename(requested_path)}\""
      )
      |> send_chunked(200)

    stream_chunks(conn, node, resolved_path, 0, size)
  end

  defp stream_chunks(conn, _node, _path, offset, size) when offset >= size, do: conn

  defp stream_chunks(conn, node, path, offset, size) do
    len = min(@chunk_bytes, size - offset)

    case Cluster.rpc(node, __MODULE__, :read_chunk, [path, offset, len]) do
      {:ok, ""} ->
        conn

      {:ok, data} when is_binary(data) ->
        case chunk(conn, data) do
          {:ok, conn} -> stream_chunks(conn, node, path, offset + byte_size(data), size)
          # Client disconnected mid-download — stop, nothing left to serve.
          {:error, _} -> conn
        end

      # A mid-stream failure (file deleted, node dropped) after headers are
      # already flushed — the response is chunked, so there's no way to
      # surface a fresh status code at this point. Best we can do is stop,
      # leaving the browser with a truncated (and thus visibly failed)
      # download rather than hanging forever.
      _ ->
        conn
    end
  end

  defp error_response(conn, :outside_root), do: bad_request(conn, "Invalid path")
  defp error_response(conn, :not_found), do: not_found(conn)
  defp error_response(conn, :not_a_file), do: bad_request(conn, "Not a downloadable file")
  defp error_response(conn, :too_large), do: text_error(conn, 413, "File too large to download")

  defp error_response(conn, {:rpc_undef, _}),
    do: text_error(conn, 503, "This node does not support file downloads yet.")

  defp error_response(conn, {:rpc_timeout, _}),
    do: text_error(conn, 504, "Timed out reading the file from its node.")

  defp error_response(conn, reason) do
    case Cluster.node_unavailable_message(reason) do
      nil -> text_error(conn, 500, "Download failed")
      message -> text_error(conn, 503, message)
    end
  end

  defp not_found(conn), do: text_error(conn, 404, "File not found")
  defp bad_request(conn, message), do: text_error(conn, 400, message)

  defp text_error(conn, status, message) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, message)
  end

  # Mirrors OrcaHubWeb.ArtifactController.download_filename/1's quote/CR/LF
  # stripping (header-injection guard) — applied after Path.basename/1 so a
  # `path` value carrying a literal CR/LF can't survive into the header via
  # the trailing path segment.
  defp download_filename(path) do
    path
    |> Path.basename()
    |> String.replace(["\"", "\r", "\n"], "")
  end
end
