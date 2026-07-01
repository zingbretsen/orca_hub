defmodule OrcaHub.Discord do
  @moduledoc """
  Entry point / feature flag for the all-in-one Discord worker.

  The worker (gateway connection + session bridge) is **inert by default**.
  It only runs on a node where `DISCORD_BOT=true` AND a valid
  `DISCORD_BOT_TOKEN` is configured — in practice, the dedicated
  `orca-agent-discord` k3s pod. Every other node (hub, LAN agents, dev) leaves
  nostrum unstarted, so nothing ever dials Discord. See `config/runtime.exs`
  for where the flag/token are read and `OrcaHub.Application` for the gated
  supervision children.

  Access is further restricted by a guild allowlist (`DISCORD_GUILD_IDS`) that
  FAILS CLOSED — see `guild_allowed?/1`.
  """

  require Logger

  @doc "True when this node should run the Discord worker."
  def enabled? do
    Application.get_env(:orca_hub, :discord_bot, false) and
      is_binary(Application.get_env(:nostrum, :token))
  end

  @doc "Configured guild allowlist (list of snowflake strings)."
  def guild_ids, do: Application.get_env(:orca_hub, :discord_guild_ids, [])

  @doc """
  True only if `guild_id` is in the configured allowlist.

  **Fails closed:** an empty/unset allowlist allows nothing, and a `nil` guild
  (e.g. a DM) is never allowed. Accepts a snowflake as an integer or string.
  """
  def guild_allowed?(guild_id) when is_integer(guild_id),
    do: guild_allowed?(Integer.to_string(guild_id))

  def guild_allowed?(guild_id) when is_binary(guild_id), do: guild_id in guild_ids()
  def guild_allowed?(_), do: false

  @doc """
  Supervision children for the Discord worker, or `[]` when disabled.

  We start nostrum manually here so it never auto-connects on other nodes —
  nostrum is an `included_applications` entry in `mix.exs` (shipped in the
  release and loaded, but NOT auto-started by OTP). We use
  `Application.ensure_all_started/1` rather than supervising `Nostrum.Application`
  directly, because the latter starts nostrum's supervision tree WITHOUT
  starting its OTP application dependencies (notably `gun`, the HTTP/WebSocket
  client). Without `gun` running, `Nostrum.Shard.Supervisor` crashes when it
  dials the gateway (`gun_conns_sup` has no process). `ensure_all_started/1`
  boots gun and the rest of nostrum's deps in the correct order. The consumer
  (`OrcaHub.Discord.Bot`) is then supervised by us so `Nostrum.ConsumerGroup`
  is available to join.
  """
  def children do
    if enabled?() do
      warn_if_allowlist_empty()

      case Application.ensure_all_started(:nostrum) do
        {:ok, _apps} ->
          :ok

        {:error, reason} ->
          raise "nostrum failed to start for Discord worker: #{inspect(reason)}"
      end

      [OrcaHub.Discord.Bot]
    else
      []
    end
  end

  # Logged once at worker startup (children/0 runs once from Application.start).
  # An empty allowlist means the worker connects but ignores every message.
  defp warn_if_allowlist_empty do
    if guild_ids() == [] do
      Logger.warning(
        "Discord worker enabled but DISCORD_GUILD_IDS is empty — ignoring all messages"
      )
    end
  end
end
