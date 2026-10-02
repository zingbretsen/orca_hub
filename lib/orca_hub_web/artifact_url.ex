defmodule OrcaHubWeb.ArtifactURL do
  @moduledoc """
  Signed capability URLs for an artifact's content and its assets
  (ORCAHUB3-128) — what the viewer iframes load, and what the MCP artifact
  tools hand to agents.

  Why they exist: the viewer iframe is `sandbox="allow-scripts"`, an opaque
  origin, so its subresource requests (`<img src="assets/hero.png">`) are
  cross-site for cookie purposes and never carry Authelia's SameSite=Lax
  session cookie — forward-auth 302s them to the login page and every image
  breaks (ORCAHUB3-79). Authelia bypasses `^/api/.*` on this host, so the
  token-scoped routes live under `/api/artifacts/view/:token/*` and
  authenticate themselves: the token IS the credential (no bearer header —
  an `<img>`/`<video>` can't send one).

  A token names exactly ONE artifact id, under a salt no other token in the
  app uses, and covers that artifact's raw content plus every asset attached
  to it. The viewer loads `/api/artifacts/view/<token>/raw`, so the
  artifact's own relative `assets/<name>` URLs resolve under the same token
  with no HTML rewriting.

  `signed_at` is floored to the hour, so every mint within an hour yields the
  SAME token for an artifact: stable URLs, so the browser cache keeps working.
  Lifetime is `max_age_seconds/0` (default 24h, app env
  `:artifact_url_max_age_seconds`) counted from that floored time, so a
  freshly minted URL is good for between `max_age - 1h` and `max_age`.

  Mint on the HUB. The hub's endpoint is the one behind the public ingress:
  its `secret_key_base` is the one that verifies, and its `Endpoint.url/0` is
  the public base. Code on an agent node goes through
  `OrcaHub.HubRPC.artifact_raw_url/1`, `artifact_asset_url/2` and
  `artifact_urls/2` instead of calling this module directly.
  """

  use OrcaHubWeb, :verified_routes

  @salt "artifact view capability"
  @bucket_seconds 3600
  @default_max_age_seconds 86_400

  @doc "Token lifetime in seconds (app env `:artifact_url_max_age_seconds`, default 24h)."
  def max_age_seconds do
    Application.get_env(:orca_hub, :artifact_url_max_age_seconds, @default_max_age_seconds)
  end

  @doc """
  A token scoped to `artifact_id`. `opts[:now]` (unix seconds) overrides the
  clock — the hour floor is applied to it either way.
  """
  def mint(artifact_id, opts \\ []) when is_binary(artifact_id) do
    now = Keyword.get_lazy(opts, :now, fn -> System.system_time(:second) end)
    signed_at = div(now, @bucket_seconds) * @bucket_seconds

    Phoenix.Token.sign(OrcaHubWeb.Endpoint, @salt, artifact_id,
      signed_at: signed_at,
      max_age: max_age_seconds()
    )
  end

  @doc """
  `{:ok, artifact_id}` for a valid, unexpired token, else `:error`. Callers
  get no reason on purpose: a tampered, expired or missing token all answer
  the same 404.
  """
  def verify(token) when is_binary(token) do
    case Phoenix.Token.verify(OrcaHubWeb.Endpoint, @salt, token, max_age: max_age_seconds()) do
      {:ok, artifact_id} when is_binary(artifact_id) -> {:ok, artifact_id}
      _ -> :error
    end
  end

  def verify(_token), do: :error

  @doc """
  Relative iframe src, `/api/artifacts/view/<token>/raw?v=<version>`. The
  `?v=` busts the iframe cache on a version bump. Callers in a LiveView mint
  this into an assign when the artifact or its version changes, never in the
  template — a re-render after the hour rolls over would otherwise change
  `src` and reload the iframe, wiping its in-page state.
  """
  def raw_path(%{id: id, version: version}) do
    ~p"/api/artifacts/view/#{mint(id)}/raw?v=#{version}"
  end

  @doc "Absolute (public, endpoint-URL-based) form of `raw_path/1`."
  def raw_url(artifact), do: absolute(raw_path(artifact))

  @doc "Absolute URL of the asset attached to `artifact_id` as `name`."
  def asset_url(artifact_id, name) when is_binary(artifact_id) and is_binary(name) do
    absolute(~p"/api/artifacts/view/#{mint(artifact_id)}/assets/#{name}")
  end

  @doc """
  `%{raw_url: url, asset_urls: %{name => url}}` in one call (one RPC hop
  for a caller on an agent node).
  """
  def urls(%{id: id} = artifact, asset_names) when is_list(asset_names) do
    %{
      raw_url: raw_url(artifact),
      asset_urls: Map.new(asset_names, &{&1, asset_url(id, &1)})
    }
  end

  defp absolute(path), do: String.trim_trailing(OrcaHubWeb.Endpoint.url(), "/") <> path
end
