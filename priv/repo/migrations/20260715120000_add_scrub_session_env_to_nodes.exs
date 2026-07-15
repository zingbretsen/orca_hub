defmodule OrcaHub.Repo.Migrations.AddScrubSessionEnvToNodes do
  use Ecto.Migration

  # Per-node flag: when true, agent-CLI sessions and terminal PTYs spawned ON
  # this node get a strict allow-list environment (OrcaHub.Env.strict_env/1)
  # instead of inheriting the full BEAM environment minus release cruft — for
  # nodes that run sessions triggered by untrusted input (e.g. a Discord
  # bridge node) and shouldn't leak host/pod secrets (DISCORD_TOKEN,
  # SECRET_KEY_BASE, etc.) into a session's Bash tool. See OrcaHub.NodePolicy
  # and OrcaHub.Env.
  def change do
    alter table(:nodes) do
      add :scrub_session_env, :boolean, null: false, default: false
    end
  end
end
