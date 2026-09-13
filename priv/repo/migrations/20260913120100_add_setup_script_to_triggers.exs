defmodule OrcaHub.Repo.Migrations.AddSetupScriptToTriggers do
  use Ecto.Migration

  # A pre-run setup script: an operator-authored shell script run on the
  # session's runner node, in the session's directory, on EVERY firing of the
  # trigger (including a reuse_session firing), before the trigger prompt is
  # delivered. Its combined stdout+stderr, exit code and duration are
  # prepended to the prompt in a <setup_script> block — a "gather current
  # state before this run" hook (`date -u`, `git log -1`, `kubectl get pods`),
  # not one-time provisioning.
  #
  # NULL/blank setup_script means no script runs. setup_timeout_seconds bounds
  # it; a timeout kills the script's whole process group and the firing
  # continues with the failure surfaced in the prompt. See
  # OrcaHub.Triggers.SetupScript.
  def change do
    alter table(:triggers) do
      add :setup_script, :text
      add :setup_timeout_seconds, :integer, default: 120
    end
  end
end
