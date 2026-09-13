defmodule OrcaHub.Repo.Migrations.AddToolPolicyToTriggers do
  use Ecto.Migration

  # Per-TRIGGER MCP tool restrictions, stamped onto every session the trigger
  # spawns (OrcaHub.TriggerExecutor.create_new_session/1). Mirrors the
  # sessions.tool_allowlist/tool_denylist columns exactly — same nullable
  # {:array, :string} shape, same semantics (nil OR [] mean "no restriction"
  # on EITHER side; an explicit deny-all is tool_denylist: ["*"]; deny wins
  # over allow) — because that is literally where these values end up. See
  # OrcaHub.ToolPolicy for the matching rules and enforcement points.
  #
  # This is the declarative, ENFORCED replacement for the "you may NEVER call
  # retire_memory" English paragraphs operators write into trigger prompts.
  def change do
    alter table(:triggers) do
      add :tool_allowlist, {:array, :string}
      add :tool_denylist, {:array, :string}
    end
  end
end
