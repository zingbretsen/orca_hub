defmodule OrcaHub.Triggers.Trigger do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "triggers" do
    field :name, :string
    field :prompt, :string
    field :type, :string, default: "scheduled"
    field :cron_expression, :string
    field :webhook_secret, :string
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
      :type,
      :cron_expression,
      :webhook_secret,
      :reuse_session,
      :archive_on_complete,
      :enabled,
      :project_id,
      :last_session_id,
      :last_fired_at
    ])
    |> validate_required([:name, :prompt, :project_id, :type])
    |> validate_inclusion(:type, ["scheduled", "webhook"])
    |> maybe_generate_webhook_secret()
    |> validate_by_type()
    |> foreign_key_constraint(:project_id)
    |> unique_constraint(:webhook_secret)
  end

  defp maybe_generate_webhook_secret(changeset) do
    case get_field(changeset, :type) do
      "webhook" ->
        if get_field(changeset, :webhook_secret) do
          changeset
        else
          put_change(changeset, :webhook_secret, Ecto.UUID.generate())
        end

      _ ->
        changeset
    end
  end

  defp validate_by_type(changeset) do
    case get_field(changeset, :type) do
      "scheduled" ->
        changeset
        |> validate_required([:cron_expression])
        |> validate_cron_expression()

      "webhook" ->
        changeset

      _ ->
        changeset
    end
  end

  defp validate_cron_expression(changeset) do
    case get_change(changeset, :cron_expression) do
      nil ->
        changeset

      expr ->
        parts = String.split(expr)

        if length(parts) in 5..7 do
          changeset
        else
          add_error(changeset, :cron_expression, "is not a valid cron expression")
        end
    end
  end
end
