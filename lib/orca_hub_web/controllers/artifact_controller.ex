defmodule OrcaHubWeb.ArtifactController do
  @moduledoc """
  Serves an artifact's raw content — deliberately a plain controller action
  (no `render/2`, no app layout) so the response is exactly the
  agent-authored bytes, embedded by callers in a sandboxed iframe
  (`sandbox="allow-scripts"`, never `allow-same-origin`).

  That iframe sandbox is the boundary, but only for the embedding page:
  nothing stops a top-level navigation straight to `/artifacts/:id/raw`
  (or an HTML/SVG asset), where the agent-authored bytes would otherwise
  run on the app's authenticated origin. So every response here also
  carries the sandbox ITSELF via `Content-Security-Policy: sandbox ...`
  (ORCAHUB3-75) — the raw route with exactly the iframe's tokens, so the
  framed behaviour is unchanged and a direct navigation gets the same
  opaque origin. `sandbox` is the ONLY directive: it is not a fetch
  directive, so CDN scripts (Chart.js, mermaid, Tailwind Play, etc.) and
  inline scripts keep loading. Keep `@raw_sandbox` in lockstep with the
  viewer iframes' `sandbox` attribute (ArtifactLive.Show,
  SessionLive.Show).

  ## Two route families, same bytes

    * `/artifacts/:id/{raw,download,assets/:name}`: no app-level auth;
      Authelia forward-auth at the ingress covers them. Kept for backward
      compatibility and for the download button.
    * `/api/artifacts/view/:token/{raw,assets/:name}` (ORCAHUB3-128): what
      both viewer iframes load. The iframe is an opaque origin, so its
      `<img>`/`<video>`/fetch requests are cross-site for cookie purposes
      and never carry Authelia's SameSite=Lax cookie. On the `/artifacts`
      routes forward-auth 302'd every asset to the login page
      (ORCAHUB3-79). Authelia bypasses `^/api/.*` on this host, so these
      routes authenticate themselves: the signed, artifact-scoped token in
      the path is the credential (`OrcaHubWeb.ArtifactURL`). A relative
      `assets/<name>` inside the artifact resolves under the same token, so
      no HTML is rewritten. An invalid, expired, tampered or other-artifact
      token gets the same bare 404 as a missing artifact. Asset responses
      add `Access-Control-Allow-Origin: *` (opaque-origin fetch()/@font-face
      are CORS-mode; no cookie is involved) and `Referrer-Policy:
      no-referrer`.

  Both asset routes answer single-range HTTP Range requests with 206 (iOS
  Safari won't play a `<video>` without it), reading only the requested
  window from the object store.
  """

  use OrcaHubWeb, :controller

  alias OrcaHub.Artifacts.Render
  alias OrcaHub.HubRPC
  alias OrcaHubWeb.ArtifactURL

  # Must match the viewer iframes' sandbox attribute exactly — never add
  # allow-same-origin.
  @raw_sandbox "sandbox allow-scripts"
  # Assets are subresources (<img>, <link>, fetch) — CSP sandbox only
  # applies to documents, so this never affects an asset loaded BY an
  # artifact, only one navigated to directly. No scripts needed there.
  @asset_sandbox "sandbox"

  def raw(conn, %{"id" => id}) do
    case HubRPC.get_artifact(id) do
      nil -> not_found(conn)
      artifact -> send_raw(conn, artifact)
    end
  end

  # Token-scoped twin of raw/2 (ORCAHUB3-128): same bytes and headers. The
  # token names the artifact, so there is no id in the path to check.
  # `strict-origin-when-cross-origin` pins what the browser already does by
  # default: the token-bearing URL goes out as a Referer only same-origin
  # (the artifact's own asset requests), a cross-origin request (a CDN, a
  # tile server that wants a Referer) sees only the origin.
  def view_raw(conn, %{"token" => token}) do
    with {:ok, id} <- ArtifactURL.verify(token),
         %{} = artifact <- HubRPC.get_artifact(id) do
      conn
      |> put_resp_header("referrer-policy", "strict-origin-when-cross-origin")
      |> send_raw(artifact)
    else
      _ -> not_found(conn)
    end
  end

  defp send_raw(conn, artifact) do
    conn
    |> put_resp_content_type(Render.content_type(artifact.kind))
    |> sandbox(@raw_sandbox)
    |> send_resp(200, Render.body(artifact))
  end

  # Same body/content-type as raw/2 (so the downloaded file is byte-identical
  # to what the iframe renders), plus a content-disposition header so the
  # browser saves it instead of navigating to it.
  def download(conn, %{"id" => id}) do
    case HubRPC.get_artifact(id) do
      nil ->
        not_found(conn)

      artifact ->
        conn
        |> put_resp_content_type(Render.content_type(artifact.kind))
        |> sandbox(@asset_sandbox)
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"#{download_filename(artifact)}\""
        )
        |> send_resp(200, Render.body(artifact))
    end
  end

  # Serves an asset attached via the attach_artifact_asset MCP tool
  # (ORCAHUB3-72 slice 2) — the artifact's own HTML loads it as a relative
  # URL (e.g. <img src="assets/hero.png">), which resolves here when the
  # artifact itself was loaded from /artifacts/:id/raw (the viewers now use
  # the token route, view_asset/3 below). No visibility check: an artifact
  # asset is exactly as reachable as the artifact's own content (see this
  # controller's moduledoc).
  def asset(conn, %{"id" => id, "name" => name}) do
    send_asset(conn, id, name)
  end

  # Token-scoped twin of asset/3 (ORCAHUB3-128) — what a relative
  # `assets/<name>` resolves to inside an artifact loaded from view_raw/2.
  # `Access-Control-Allow-Origin: *` because the opaque-origin iframe's
  # fetch() and @font-face loads are CORS-mode requests; safe here because
  # no cookie is involved and the URL itself is the capability.
  # `no-referrer` so an asset that is itself a document (an HTML/SVG asset
  # navigated to) never forwards the token-bearing URL.
  def view_asset(conn, %{"token" => token, "name" => name}) do
    case ArtifactURL.verify(token) do
      {:ok, id} ->
        conn
        |> put_resp_header("access-control-allow-origin", "*")
        |> put_resp_header("referrer-policy", "no-referrer")
        |> send_asset(id, name)

      :error ->
        not_found(conn)
    end
  end

  # HTTP Range (RFC 9110 §14) on both asset routes: iOS Safari won't play a
  # <video> unless byte ranges come back as 206. A single range reads only
  # that window from the object store (ObjectStore.get_range/3 via HubRPC),
  # never the whole object. No Range header, several Range headers, a
  # multi-range or a malformed one all get the whole file as a 200 (a
  # server MAY ignore Range). A range starting at or past the end is a 416.
  defp send_asset(conn, id, name) do
    case HubRPC.get_artifact_asset(id, name) do
      %{file: %{} = file} ->
        size = file.size_bytes

        case requested_range(get_req_header(conn, "range"), size) do
          :full -> send_full_asset(conn, file)
          {first, last} -> send_partial_asset(conn, file, first, last)
          :unsatisfiable -> send_unsatisfiable(conn, file)
        end

      _ ->
        not_found(conn)
    end
  end

  defp send_full_asset(conn, file) do
    case HubRPC.fetch_file_binary(file) do
      {:ok, binary} -> conn |> asset_headers(file) |> send_resp(200, binary)
      _ -> not_found(conn)
    end
  end

  defp send_partial_asset(conn, file, first, last) do
    case HubRPC.fetch_file_binary_range(file, first, last - first + 1) do
      # Content-Range from the bytes actually read, in case the stored
      # object is shorter than its size_bytes says.
      {:ok, data} when byte_size(data) > 0 ->
        conn
        |> asset_headers(file)
        |> put_resp_header(
          "content-range",
          "bytes #{first}-#{first + byte_size(data) - 1}/#{file.size_bytes}"
        )
        |> send_resp(206, data)

      {:ok, _empty} ->
        send_unsatisfiable(conn, file)

      {:error, :range_not_satisfiable} ->
        send_unsatisfiable(conn, file)

      _ ->
        not_found(conn)
    end
  end

  defp send_unsatisfiable(conn, file) do
    conn
    |> asset_headers(file)
    |> put_resp_header("content-range", "bytes */#{file.size_bytes}")
    |> send_resp(416, "")
  end

  defp asset_headers(conn, file) do
    conn
    |> put_resp_content_type(file.content_type || "application/octet-stream")
    |> put_resp_header("cache-control", "private, max-age=3600")
    |> put_resp_header("accept-ranges", "bytes")
    |> sandbox(@asset_sandbox)
  end

  # `{first, last}` (inclusive, clamped to the file), `:unsatisfiable`, or
  # `:full`. An empty file has no satisfiable byte range to answer with, so
  # it is always served whole.
  defp requested_range([header], size) when size > 0 do
    case Regex.run(~r/\Abytes=(\d*)-(\d*)\z/, String.trim(header)) do
      [_, "", ""] -> :full
      [_, "", suffix] -> suffix_range(String.to_integer(suffix), size)
      [_, first, last] -> bounded_range(String.to_integer(first), parse_last(last), size)
      nil -> :full
    end
  end

  defp requested_range(_headers, _size), do: :full

  defp suffix_range(0, _size), do: :unsatisfiable
  defp suffix_range(n, size), do: {max(size - n, 0), size - 1}

  defp parse_last(""), do: nil
  defp parse_last(last), do: String.to_integer(last)

  # last < first is a syntactically invalid range: ignored, not a 416.
  defp bounded_range(first, last, _size) when is_integer(last) and last < first, do: :full
  defp bounded_range(first, _last, size) when first >= size, do: :unsatisfiable
  defp bounded_range(first, nil, size), do: {first, size - 1}
  defp bounded_range(first, last, size), do: {first, min(last, size - 1)}

  defp sandbox(conn, csp) do
    conn
    |> put_resp_header("content-security-policy", csp)
    |> put_resp_header("x-content-type-options", "nosniff")
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Artifact not found")
  end

  defp extension("svg"), do: ".svg"
  defp extension(_html_or_markdown), do: ".html"

  # Sanitizes artifact.name into a safe filename: only [A-Za-z0-9._-], no
  # collapsed repeats, no leading/trailing dash/dot, falling back to
  # "artifact-<id>" if nothing survives. Avoids double-appending the
  # extension if the sanitized name already ends with it.
  defp download_filename(artifact) do
    ext = extension(artifact.kind)

    base =
      (artifact.name || "")
      |> String.replace(~r/[^A-Za-z0-9._-]+/, "-")
      |> String.replace(~r/-{2,}/, "-")
      |> String.replace(~r/^[.-]+|[.-]+$/, "")

    base = if base == "", do: "artifact-#{artifact.id}", else: base

    filename = if String.ends_with?(base, ext), do: base, else: base <> ext

    # Quote-escaping: the sanitized charset above can never contain a `"` or
    # a newline, but escape defensively anyway in case that regex ever
    # changes.
    String.replace(filename, ["\"", "\r", "\n"], "")
  end
end
