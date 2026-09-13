defmodule OrcaHub.Repo.Migrations.AddToolPolicyToSessions do
  use Ecto.Migration

  # Per-session MCP tool restrictions, enforced in the MCP server (see
  # OrcaHub.ToolPolicy). Entries are matched against the RAW MCP tool name
  # (`send_message_to_session`, `github__get_issue`) and may contain `*` as a
  # glob.
  #
  # Both columns are NULLABLE with NO default, and nil/[] mean "no
  # restriction" for BOTH of them — deliberately: Phoenix form/multi-select
  # casting turns an untouched field into `[]`, and an `[] == deny everything`
  # reading would silently strip every tool from a session. An explicit
  # deny-all is spelled `tool_denylist: ["*"]`.
  def change do
    alter table(:sessions) do
      add :tool_allowlist, {:array, :string}
      add :tool_denylist, {:array, :string}
    end
  end
end
