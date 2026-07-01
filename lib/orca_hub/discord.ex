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
  """

  @doc "True when this node should run the Discord worker."
  def enabled? do
    Application.get_env(:orca_hub, :discord_bot, false) and
      is_binary(Application.get_env(:nostrum, :token))
  end

  @doc """
  Supervision children for the Discord worker, or `[]` when disabled.

  We start nostrum's own application tree manually (via its `child_spec/1`) so
  it never auto-connects on other nodes — see the `runtime: false` note in
  `mix.exs`. The consumer starts after nostrum so `Nostrum.ConsumerGroup` is
  available to join.
  """
  def children do
    if enabled?() do
      [
        Nostrum.Application,
        OrcaHub.Discord.Bot
      ]
    else
      []
    end
  end
end
