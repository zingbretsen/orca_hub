import Config
import Dotenvy

if config_env() in [:dev, :test] do
  source!([".env"])
end

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/orca_hub start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
orca_mode =
  case System.get_env("ORCA_MODE", "hub") do
    "agent" -> :agent
    _ -> :hub
  end

config :orca_hub, :mode, orca_mode

# Long-lived streaming SessionRunner engine — now the DEFAULT (ON).
# ORCA_DISABLE_STREAMING is a global KILL SWITCH: set it to "1"/"true" to flip
# the default back to the one-shot engine for new runners. Unset/anything-else
# leaves streaming ON. A per-session `streaming` column (see Sessions.Session)
# still overrides this default — including `streaming: true` winning over the
# kill switch (see SessionRunner.resolve_engine/1 for the documented caveat).
config :orca_hub,
       :disable_streaming,
       System.get_env("ORCA_DISABLE_STREAMING") in ~w(1 true)

# "Code execution with MCP" is opt-in per session and DARK BY DEFAULT.
# ORCA_DISABLE_CODE_EXEC is a global KILL SWITCH: set it to "1"/"true" to
# force-disable the feature node-wide regardless of any per-session opt-in.
config :orca_hub,
       :disable_code_exec,
       System.get_env("ORCA_DISABLE_CODE_EXEC") in ~w(1 true)

# OrcaHub.SessionResumer's boot-time orphan-resume sweep — ON by default.
# ORCA_AUTO_RESUME=false/0 disables it node-wide.
config :orca_hub,
       :auto_resume,
       System.get_env("ORCA_AUTO_RESUME") not in ~w(0 false)

# Base64-encoded 32-byte key used by OrcaHub.Secrets to encrypt/decrypt
# upstream-injection secrets at rest (AES-256-GCM). Hub-only; raises a clear
# error at use time (not at boot) if unset or malformed.
config :orca_hub, :secrets_key, System.get_env("ORCA_SECRETS_KEY")

# Static bearer token for the Agent Runs API (docs/api.md), homelab-internal
# auth via OrcaHubWeb.Plugs.ApiAuth. Unset/empty means the API is disabled
# (503 on every request), not "open".
config :orca_hub,
       :api_token,
       System.get_env("ORCA_API_TOKEN") |> then(fn v -> if v in [nil, ""], do: nil, else: v end)

if System.get_env("PHX_SERVER") do
  config :orca_hub, OrcaHubWeb.Endpoint, server: true
end

# All-in-one Discord worker. INERT BY DEFAULT: nostrum is an
# `included_applications` entry (see mix.exs) — shipped/loaded but not
# auto-started — and OrcaHub.Application only starts it when BOTH the flag and a
# token are set. On every other node (hub, LAN agents, dev) the flag is off, no
# token is configured, and nothing dials Discord.
discord_bot? = System.get_env("DISCORD_BOT") in ~w(1 true)
config :orca_hub, :discord_bot, discord_bot?

if discord_bot? do
  case System.get_env("DISCORD_BOT_TOKEN") do
    token when is_binary(token) and token != "" ->
      config :nostrum, token: token

    _ ->
      raise """
      DISCORD_BOT=true but DISCORD_BOT_TOKEN is missing/empty.
      Set DISCORD_BOT_TOKEN (from the Discord dev portal Bot tab) or unset
      DISCORD_BOT to disable the Discord worker.
      """
  end
end

# Guild allowlist for the Discord worker (comma-separated guild/server
# snowflakes). These are NOT secret — plain env, not the k8s secret. The gate
# FAILS CLOSED: an empty/unset list means the worker ignores every message
# (see OrcaHub.Discord.guild_allowed?/1).
discord_guild_ids =
  case System.get_env("DISCORD_GUILD_IDS") do
    nil -> []
    "" -> []
    str -> str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
  end

config :orca_hub, :discord_guild_ids, discord_guild_ids

config :orca_hub, OrcaHubWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

config :orca_hub, :gotify_url, System.get_env("GOTIFY_URL")
config :orca_hub, :gotify_token, System.get_env("GOTIFY_TOKEN")
config :orca_hub, :elevenlabs_api_key, System.get_env("ELEVENLABS_API_KEY")

config :orca_hub,
       :elevenlabs_voice_id,
       System.get_env("ELEVENLABS_VOICE_ID") || "JBFqnCBsd6RMkjVDRZzb"

# pg-provisioner bearer token — lets Tools.provision_database/list_databases
# (OrcaHub.MCP.Tools.Databases) call the homelab shared-postgres provisioning
# API on the session's behalf, so sessions never fetch/hold the token
# themselves. The MCP server for a session runs on the session's own runner
# node, so this must be set on every node (k3s pods + systemd hosts), not
# just the hub.
config :orca_hub, :pgprov_api_token, System.get_env("PGPROV_API_TOKEN")

config :orca_hub,
       :pgprov_api_url,
       System.get_env("PGPROV_API_URL") || "https://pgprov.lab.ingbretsenhome.com"

# Upload sidecar running alongside playwright-mcp in its pod — lets code-exec
# push a LOCAL (OrcaHub-node) file into that pod's own filesystem so
# `browser_file_upload`/`browser_drop` (which read `paths` from the pod, not
# from here) can reach it. See `OrcaHub.MCP.CodeExec.PlaywrightUpload`.
config :orca_hub,
       :playwright_upload_url,
       System.get_env("PLAYWRIGHT_UPLOAD_URL") || "http://127.0.0.1:30932"

# Libcluster topology configuration
# Supports multiple strategies simultaneously:
# - K8s DNS for in-cluster pod discovery (set CLUSTER_DNS_QUERY)
# - Static EPMD for external nodes like laptops (set CLUSTER_NODES)
cluster_topologies = []

cluster_topologies =
  case System.get_env("CLUSTER_DNS_QUERY") do
    nil ->
      cluster_topologies

    query ->
      [
        {:k8s_dns,
         [
           strategy: Cluster.Strategy.DNSPoll,
           config: [
             polling_interval: 5_000,
             query: query,
             node_basename: System.get_env("RELEASE_NODE_BASENAME", "orca")
           ]
         ]}
        | cluster_topologies
      ]
  end

cluster_topologies =
  case System.get_env("CLUSTER_NODES") do
    nil ->
      cluster_topologies

    nodes ->
      hosts = nodes |> String.split(",") |> Enum.map(&String.to_atom(String.trim(&1)))

      [
        {:static,
         [
           strategy: Cluster.Strategy.Epmd,
           config: [hosts: hosts, timeout: 5_000]
         ]}
        | cluster_topologies
      ]
  end

config :libcluster, topologies: cluster_topologies

if config_env() == :prod do
  if orca_mode == :hub do
    database_url =
      System.get_env("DATABASE_URL") ||
        raise """
        environment variable DATABASE_URL is missing.
        For example: ecto://USER:PASS@HOST/DATABASE
        """

    maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

    config :orca_hub, OrcaHub.Repo,
      # ssl: true,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      # For machines with several cores, consider starting multiple pools of `pool_size`
      # pool_count: 4,
      socket_options: maybe_ipv6
  end

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"
  scheme = System.get_env("PHX_SCHEME") || "http"

  url_port =
    String.to_integer(
      System.get_env("PHX_URL_PORT") || if(scheme == "https", do: "443", else: "80")
    )

  config :orca_hub, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  # Optional listener bind address override (default: "::", i.e. all
  # interfaces on IPv4+IPv6). Lets a node bind to a narrower address, e.g.
  # 127.0.0.1 for a LAN systemd agent that should only be reachable via its
  # cluster/loopback interface.
  listen_ip =
    case System.get_env("PHX_LISTEN_IP") do
      nil ->
        {0, 0, 0, 0, 0, 0, 0, 0}

      "" ->
        {0, 0, 0, 0, 0, 0, 0, 0}

      ip_str ->
        case :inet.parse_address(String.to_charlist(ip_str)) do
          {:ok, ip} ->
            ip

          {:error, _} ->
            raise """
            PHX_LISTEN_IP is set to an unparseable IP address: #{inspect(ip_str)}
            Expected a plain IPv4 or IPv6 address, e.g. "127.0.0.1" or "::1".
            """
        end
    end

  extra_origins =
    case System.get_env("PHX_EXTRA_ORIGINS") do
      nil -> []
      "" -> []
      str -> str |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))
    end

  config :orca_hub, OrcaHubWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    check_origin:
      [
        "#{scheme}://#{host}",
        "#{scheme}://#{host}:#{url_port}"
      ] ++ extra_origins,
    http: [
      # Defaults to "::" (all interfaces, IPv4+IPv6). Override via
      # PHX_LISTEN_IP (see above) for e.g. loopback-only access.
      # See the documentation on https://hexdocs.pm/bandit/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: listen_ip
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :orca_hub, OrcaHubWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://hexdocs.pm/plug/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :orca_hub, OrcaHubWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :orca_hub, OrcaHub.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://hexdocs.pm/swoosh/Swoosh.html#module-installation for details.
end
