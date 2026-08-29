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

  # Declarative auto-persist helper for [data-orca-persist="key"] elements,
  # injected into every html-kind artifact (see inject_scripts/2 below).
  # Dependency-free plain DOM APIs only — this runs inside the sandboxed
  # iframe (`allow-scripts`, no `allow-same-origin`), which has no
  # localStorage/sessionStorage/cookies/IndexedDB (opaque origin), so
  # setState/getState → postMessage → the parent → the DB is the only
  # persistence path. Idempotent by construction: applying the same state
  # twice just re-sets the same .checked/.value, and setting those
  # programmatically never fires "change", so an incoming orca:data message
  # can never trigger a write-back loop.
  @persist_shim """
  (function() {
    function valueOf(el) {
      return (el.type === "checkbox" || el.type === "radio") ? el.checked : el.value;
    }
    function applyValue(el, v) {
      if (el.type === "checkbox" || el.type === "radio") {
        el.checked = !!v;
      } else {
        el.value = v;
      }
    }
    function applyState(state) {
      state = state || {};
      document.querySelectorAll("[data-orca-persist]").forEach(function(el) {
        var key = el.getAttribute("data-orca-persist");
        if (Object.prototype.hasOwnProperty.call(state, key)) applyValue(el, state[key]);
      });
    }
    var pendingPatch = {};
    var debounceTimer = null;
    function flush() {
      if (debounceTimer) { clearTimeout(debounceTimer); debounceTimer = null; }
      if (Object.keys(pendingPatch).length === 0) return;
      var patch = pendingPatch;
      pendingPatch = {};
      window.orca.setState(patch);
    }
    function wire(el) {
      var key = el.getAttribute("data-orca-persist");
      el.addEventListener("change", function() {
        var patch = {};
        patch[key] = valueOf(el);
        window.orca.setState(patch);
      });
      el.addEventListener("input", function() {
        pendingPatch[key] = valueOf(el);
        if (debounceTimer) clearTimeout(debounceTimer);
        debounceTimer = setTimeout(flush, 300);
      });
    }
    document.addEventListener("DOMContentLoaded", function() {
      applyState(window.ORCA_DATA && window.ORCA_DATA._user_state);
      document.querySelectorAll("[data-orca-persist]").forEach(wire);
    });
    window.addEventListener("pagehide", flush);
    window.addEventListener("message", function(e) {
      if (e.data && e.data.type === "orca:data") applyState(e.data.data && e.data.data._user_state);
    });
  })();
  """

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
      <body>#{content |> Markdown.render(copy_code: false) |> Phoenix.HTML.safe_to_string()}</body>
    </html>
    """
  end

  defp body(%{kind: "html", content: content, data: data}) do
    inject_scripts(content || "", data || %{})
  end

  defp body(%{content: content}), do: content || ""

  # Injects three <script> tags immediately after the opening <head> tag (or
  # prepended if there's no <head> at all), html kind only:
  #
  #   1. window.ORCA_DATA = <json>; — the initial snapshot half of the
  #      live-data channel (OrcaHub.Artifacts.update_artifact_data/2 carries
  #      later updates via postMessage instead, since the iframe's opaque
  #      sandbox origin can't fetch() this host).
  #   2. window.orca = { send, setState, getState }; — send is the Phase-3
  #      bridge (submit interaction data back into the session as a
  #      user-visible message); setState/getState are the user-state
  #      persistence channel (OrcaHub.Artifacts.merge_user_state/2): a
  #      shallow-merge patch written through to `data["_user_state"]`. The
  #      parent hook (`ArtifactData` in assets/js/app.js) listens for both
  #      postMessage types and forwards them to the LiveView.
  #   3. the auto-persist shim — wires any `[data-orca-persist="key"]`
  #      element to setState/getState with no JS required from the artifact
  #      author: restores its value from `_user_state` on load and on every
  #      `orca:data` postMessage (so a second viewer's ticks show up live),
  #      writes through on `change` immediately and on `input` debounced
  #      (flushed on `pagehide`). See PERSIST_SHIM below.
  #
  # safe_json/1 replaces every "<" in the encoded JSON with its JS unicode
  # escape so no data value (e.g. one literally containing the string
  # "</script>") can break out of the injected tag — JSON only ever uses "<"
  # inside string values, never as structural syntax, so the escape can
  # never corrupt otherwise-valid JSON. The persist shim has no interpolated
  # data, so it's injected verbatim.
  defp inject_scripts(html, data) do
    scripts =
      "<script>window.ORCA_DATA = #{safe_json(data)};</script>" <>
        "<script>window.orca = { " <>
        "send: function(payload) { window.parent.postMessage({type: \"orca:send\", payload: payload}, \"*\"); }, " <>
        "setState: function(patch) { window.parent.postMessage({type: \"orca:state\", patch: patch}, \"*\"); }, " <>
        "getState: function() { return (window.ORCA_DATA && window.ORCA_DATA._user_state) || {}; } " <>
        "};</script>" <>
        "<script>#{@persist_shim}</script>"

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
