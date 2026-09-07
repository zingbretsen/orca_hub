defmodule OrcaHubWeb.ArtifactController do
  @moduledoc """
  Serves an artifact's raw content — deliberately a plain controller action
  (no `render/2`, no app layout, no CSP) so the response is exactly the
  agent-authored bytes, embedded by callers in a sandboxed iframe
  (`sandbox="allow-scripts"`, never `allow-same-origin`). That iframe
  sandbox is the security boundary; a restrictive CSP here would break
  artifacts that intentionally load CDN scripts (Chart.js, mermaid,
  Tailwind Play, etc.) and isn't needed on top of it.
  """

  use OrcaHubWeb, :controller

  alias OrcaHub.Artifacts.Render
  alias OrcaHub.HubRPC

  def raw(conn, %{"id" => id}) do
    case HubRPC.get_artifact(id) do
      nil ->
        not_found(conn)

      artifact ->
        conn
        |> put_resp_content_type(Render.content_type(artifact.kind))
        |> send_resp(200, Render.body(artifact))
    end
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
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"#{download_filename(artifact)}\""
        )
        |> send_resp(200, Render.body(artifact))
    end
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
