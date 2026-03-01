defmodule OrcaHub.Triggers.Trigger do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "triggers" do
    field :name, :string
    field :prompt, :string
    field :cron_expression, :string
    field :reuse_session, :boolean, default: false
    field :archive_on_complete, :boolean, default: false
    field :enabled, :boolean, default: true
    field :last_session_id, :binary_id
    field :last_fired_at, :utc_datetime

    belongs_to :project, OrcaHub.Projects.Project

    timestamps()
  end

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [
      :name,
      :prompt,
      :cron_expression,
      :reuse_session,
      :archive_on_complete,
      :enabled,
      :project_id,
      :last_session_id,
      :last_fired_at
    ])
    |> validate_required([:name, :prompt, :cron_expression, :project_id])
    |> validate_cron_expression()
    |> foreign_key_constraint(:project_id)
  end

  defp validate_cron_expression(changeset) do
    case get_change(changeset, :cron_expression) do
      nil ->
        changeset

      expr ->
        case Crontab.CronExpression.Parser.parse(expr) do
          {:ok, _} -> changeset
          {:error, _} -> add_error(changeset, :cron_expression, "is not a valid cron expression")
        end
    end
  end
end
