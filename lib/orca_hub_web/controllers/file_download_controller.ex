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

  ## Inline previews (ORCAHUB3-77)

  `?disposition=inline` serves the file `inline` instead, but only when its
  `MIME.from_path/1` type is on `OrcaHubWeb.FilePreview`'s image/video
  allow-list; anything else (text/html included) still gets `attachment`.
  The CSP sandbox and `nosniff` headers go on every response either way.

  Inline responses also honour a single HTTP `Range` (`bytes=a-b`,
  `bytes=a-`, `bytes=-n`) with a 206, which `<video>` needs: iOS Safari
  won't play without it, and seeking needs it everywhere. Each 206 is
  clamped to `@max_range_bytes` (a short 206 is legal, and media elements
  just ask for the next range), so every response stays bounded however big
  the file is. That bound is what the whole-file cap is for, so ranged
  reads skip `@max_bytes` and a long screen recording still plays and
  seeks. An unsatisfiable range gets a 416. A multi-range, malformed or
  `If-Range` request falls back to the whole-file 200, cap included.
  Downloads (`attachment`) ignore `Range` and advertise no `Accept-Ranges`,
  exactly as before, so a resumed download can't receive a clamped body.
  """
  use OrcaHubWeb, :controller

  alias OrcaHub.{Cluster, HubRPC, PathConfinement}
  alias OrcaHubWeb.FilePreview

  # Upper bound on a single download — comfortably above any working-
  # directory artifact we expect (screenshots, PDFs, small archives), far
  # below something that would tie up a chunked response indefinitely.
  @max_bytes 200 * 1024 * 1024
  @chunk_bytes 1024 * 1024
  # Upper bound on one 206 body. Big enough that a player isn't
  # re-requesting constantly (8 rpc chunks per response), small enough that
  # a stalled or abandoned range doesn't hold much.
  @max_range_bytes 8 * 1024 * 1024

  # Raised when a read fails after the headers (and a content-length) are
  # already out. Returning normally would leave a keep-alive connection
  # whose client is still waiting for the missing bytes; raising makes the
  # server drop the connection, so the browser sees a failed response.
  defmodule StreamAbortedError do
    defexception [:message, plug_status: 500]
  end

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

  defp stream_download(conn, node, root, %{"path" => path} = params) when is_binary(path) do
    mime = MIME.from_path(path)
    inline? = params["disposition"] == "inline" and FilePreview.inline_type?(mime)
    range = if inline?, do: requested_range(conn), else: :none
    max_bytes = if range == :none, do: @max_bytes, else: :infinity

    case Cluster.rpc(node, __MODULE__, :stat_confined, [root, path, max_bytes]) do
      {:ok, resolved, size} ->
        conn
        |> put_file_headers(path, mime, inline?)
        |> serve_file(node, resolved, size, range)

      {:error, reason} ->
        error_response(conn, reason)
    end
  end

  defp stream_download(conn, _node, _root, _params),
    do: bad_request(conn, "Missing path parameter")

  # The single byte range a request asks for: `{first, last | nil}` or
  # `{:suffix, n}`, or `:none` to serve the whole file. Per RFC 9110 a
  # malformed or multi-range header is ignored rather than refused, and so
  # is any `If-Range`: we send no validators, so one can never match.
  defp requested_range(conn) do
    case {get_req_header(conn, "range"), get_req_header(conn, "if-range")} do
      {[value], []} -> parse_range(value)
      _ -> :none
    end
  end

  defp parse_range(value) do
    case Regex.run(~r/\A\s*bytes\s*=\s*(\d{0,19})\s*-\s*(\d{0,19})\s*\z/i, value) do
      [_, "", ""] -> :none
      [_, "", suffix] -> {:suffix, String.to_integer(suffix)}
      [_, first, ""] -> {String.to_integer(first), nil}
      [_, first, last] -> closed_range(String.to_integer(first), String.to_integer(last))
      nil -> :none
    end
  end

  defp closed_range(first, last) when last >= first, do: {first, last}
  defp closed_range(_first, _last), do: :none

  # Resolves a requested range against the file size to the inclusive
  # `{first, last}` actually served (clamped to @max_range_bytes), or
  # :unsatisfiable.
  defp satisfiable_range({:suffix, n}, size) when n > 0 and size > 0,
    do: clamp_range(max(size - n, 0), size - 1)

  defp satisfiable_range({:suffix, _n}, _size), do: :unsatisfiable

  defp satisfiable_range({first, last}, size) when first < size,
    do: clamp_range(first, min(last || size - 1, size - 1))

  defp satisfiable_range({_first, _last}, _size), do: :unsatisfiable

  defp clamp_range(first, last), do: {first, min(last, first + @max_range_bytes - 1)}

  # Exported (not just private) because `Cluster.rpc/5` invokes this ON THE
  # OWNING NODE via :erpc — `PathConfinement.confine/2` is realpath-based
  # and needs the real filesystem underneath it. Rejects anything that
  # isn't a regular file (a directory, socket, device, or broken symlink)
  # and anything over `max_bytes` (`:infinity` for a ranged read, whose
  # response is bounded by the clamp instead). The 2-arity form is the
  # pre-ORCAHUB3-77 export, kept for an older hub calling into this node.
  @doc false
  def stat_confined(root, path), do: stat_confined(root, path, @max_bytes)

  @doc false
  def stat_confined(root, path, max_bytes) do
    with {:ok, resolved} <- PathConfinement.confine(root, path),
         {:ok, %File.Stat{type: :regular, size: size}} <- File.stat(resolved) do
      if is_integer(max_bytes) and size > max_bytes,
        do: {:error, :too_large},
        else: {:ok, resolved, size}
    else
      {:ok, %File.Stat{}} -> {:error, :not_a_file}
      {:error, :outside_root} -> {:error, :outside_root}
      {:error, _posix} -> {:error, :not_found}
    end
  end

  # Exported for the same reason as stat_confined/3 above. A stateless,
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

  defp put_file_headers(conn, requested_path, mime, inline?) do
    disposition = if inline?, do: "inline", else: "attachment"

    conn
    # A charset on an image/video type means nothing; downloads keep theirs.
    |> put_resp_content_type(mime, if(inline?, do: nil, else: "utf-8"))
    |> put_resp_header(
      "content-disposition",
      "#{disposition}; filename=\"#{download_filename(requested_path)}\""
    )
    # Defense in depth (ORCAHUB3-75): these are agent-writable working-
    # directory bytes on the authenticated origin. An `attachment` doesn't
    # render at all, and an inline response is only ever an allow-listed
    # image/video type, but an opaque, script-less sandbox and no MIME
    # sniffing keep either inert — an SVG opened by direct navigation
    # can't run its scripts.
    |> put_resp_header("content-security-policy", "sandbox")
    |> put_resp_header("x-content-type-options", "nosniff")
    |> then(&if(inline?, do: put_resp_header(&1, "accept-ranges", "bytes"), else: &1))
  end

  # Headers go out with an exact content-length, then the body follows in
  # @chunk_bytes rpc reads (raw, not chunk-encoded, since the length is
  # known).
  defp serve_file(conn, node, resolved_path, size, :none) do
    conn
    |> put_resp_header("content-length", Integer.to_string(size))
    |> send_chunked(200)
    |> stream_chunks(node, resolved_path, 0, size)
  end

  defp serve_file(conn, node, resolved_path, size, range) do
    case satisfiable_range(range, size) do
      {first, last} ->
        conn
        |> put_resp_header("content-range", "bytes #{first}-#{last}/#{size}")
        |> put_resp_header("content-length", Integer.to_string(last - first + 1))
        |> send_chunked(206)
        |> stream_chunks(node, resolved_path, first, last + 1)

      :unsatisfiable ->
        conn
        |> delete_resp_header("content-disposition")
        |> put_resp_header("content-range", "bytes */#{size}")
        |> text_error(416, "Range not satisfiable")
    end
  end

  # Streams [offset, stop) of `path`.
  defp stream_chunks(conn, _node, _path, offset, stop) when offset >= stop, do: conn

  defp stream_chunks(conn, node, path, offset, stop) do
    len = min(@chunk_bytes, stop - offset)

    case Cluster.rpc(node, __MODULE__, :read_chunk, [path, offset, len]) do
      {:ok, data} when is_binary(data) and data != "" ->
        case chunk(conn, data) do
          {:ok, conn} -> stream_chunks(conn, node, path, offset + byte_size(data), stop)
          # Client disconnected mid-download — stop, nothing left to serve.
          {:error, _} -> conn
        end

      # A mid-stream failure (file deleted or truncated, node dropped) after
      # the headers are already out, so no fresh status code is possible
      # and the promised content-length can't be met. See
      # StreamAbortedError: the connection is dropped, so the browser sees
      # a failed response rather than hanging or a silently short file.
      other ->
        raise StreamAbortedError,
              "#{path}: read at offset #{offset} failed mid-response (#{inspect(other)})"
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
