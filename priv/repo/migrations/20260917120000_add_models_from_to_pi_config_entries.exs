defmodule OrcaHub.Repo.Migrations.AddModelsFromToPiConfigEntries do
  use Ecto.Migration

  @moduledoc """
  Opt-in dynamic model-list resolution for `kind: "provider"` rows — see
  `OrcaHub.PiModelSync`.

  The marker is a COLUMN, deliberately not a key inside `spec`: `spec` is
  written verbatim into every node's `~/.pi/agent/models.json`, so anything
  stashed in there would be clutter pi never reads (and one more field for
  pi's single-document schema validation to trip over).

  `models_from` NULL — the default, and what every existing row keeps — means
  "not managed": the row's hand-authored `models` array is left completely
  alone, exactly as today.
  """

  def change do
    alter table(:pi_config_entries) do
      # nil = not managed. Otherwise at minimum %{"url" => "..."}; see
      # OrcaHub.PiConfig.Entry for the full accepted shape.
      add :models_from, :map
      # Last SUCCESSFUL resolution (whether or not it changed the spec).
      add :models_refreshed_at, :naive_datetime
      # Last failure, cleared on the next success. Non-nil here is the ONLY
      # way an operator sees a gateway that's been unreachable for a week —
      # the never-write-an-empty-list rule makes that failure silent on disk.
      add :models_refresh_error, :text
    end
  end
end
