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

  alias OrcaHub.HubRPC
  alias OrcaHubWeb.Markdown

  def raw(conn, %{"id" => id}) do
    case HubRPC.get_artifact(id) do
      nil ->
        not_found(conn)

      artifact ->
        conn
        |> put_resp_content_type(content_type(artifact.kind))
        |> send_resp(200, body(artifact))
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
        |> put_resp_content_type(content_type(artifact.kind))
        |> put_resp_header(
          "content-disposition",
          "attachment; filename=\"#{download_filename(artifact)}\""
        )
        |> send_resp(200, body(artifact))
    end
  end

  defp not_found(conn) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(404, "Artifact not found")
  end

  defp content_type("svg"), do: "image/svg+xml"
  defp content_type(_html_or_markdown), do: "text/html"

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

  defp body(%{kind: "svg", content: content}), do: content || ""

  defp body(%{kind: "markdown", content: content}) do
    """
    <!doctype html>
    <html>
      <head>
        <meta charset="utf-8" />
        <style>
          body { font-family: system-ui, sans-serif; max-width: 860px; margin: 2rem auto; padding: 0 1rem; line-height: 1.6; }
          pre { background: #f4f4f5; padding: 0.75rem; overflow-x: auto; border-radius: 0.375rem; }
          code { font-family: ui-monospace, monospace; }
        </style>
      </head>
      <body>#{content |> Markdown.render() |> Phoenix.HTML.safe_to_string()}</body>
    </html>
    """
  end

  defp body(%{kind: "html", content: content, data: data}) do
    inject_scripts(content || "", data || %{})
  end

  defp body(%{content: content}), do: content || ""

  # Injects two <script> tags immediately after the opening <head> tag (or
  # prepended if there's no <head> at all):
  #
  #   1. window.ORCA_DATA = <json>; — the initial snapshot half of the
  #      live-data channel (OrcaHub.Artifacts.update_artifact_data/2 carries
  #      later updates via postMessage instead, since the iframe's opaque
  #      sandbox origin can't fetch() this host).
  #   2. window.orca = { send: ... }; — the orca.send bridge (Phase 3):
  #      artifact authors call `orca.send(payload)` to submit interaction
  #      data back into the session as a user-visible message. The parent
  #      hook (`ArtifactData` in assets/js/app.js) listens for the resulting
  #      postMessage and forwards it to the LiveView.
  #
  # safe_json/1 replaces every "<" in the encoded JSON with its JS unicode
  # escape so no data value (e.g. one literally containing the string
  # "</script>") can break out of the injected tag — JSON only ever uses "<"
  # inside string values, never as structural syntax, so the escape can
  # never corrupt otherwise-valid JSON.
  defp inject_scripts(html, data) do
    scripts =
      "<script>window.ORCA_DATA = #{safe_json(data)};</script>" <>
        "<script>window.orca = { send: function(payload) { window.parent.postMessage({type: \"orca:send\", payload: payload}, \"*\"); } };</script>"

    case Regex.run(~r/<head[^>]*>/i, html, return: :index) do
      [{start, len}] ->
        {pre, post} = String.split_at(html, start + len)
        pre <> scripts <> post

      nil ->
        scripts <> html
    end
  end

  defp safe_json(data), do: data |> Jason.encode!() |> String.replace("<", "\\u003c")
end
