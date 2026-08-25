defmodule OrcaHub.Triggers.Trigger do
  @moduledoc "Schema for a scheduled, webhook, or inbound-email trigger."

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
    field :pinned_at, :utc_datetime

    # type: "email" only. Addresses (or bare domains) allowed to fire this
    # trigger, matched case-insensitively against the authenticated From:
    # addr-spec. Must be non-empty — see validate_by_type/1.
    field :sender_allowlist, {:array, :string}, default: []
    # Optional routing when several triggers share one inbox: the recipient
    # address the message must have been sent to (exact, case-insensitive
    # match against To:/Cc:), and a case-insensitive SUBSTRING the subject
    # must contain (not a regex — see OrcaHub.EmailInbox.Ingest).
    field :to_address, :string
    field :subject_pattern, :string

    belongs_to :project, OrcaHub.Projects.Project
    belongs_to :email_inbox, OrcaHub.EmailInboxes.EmailInbox

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
      :last_fired_at,
      :email_inbox_id,
      :pinned_at,
      :sender_allowlist,
      :to_address,
      :subject_pattern
    ])
    |> validate_required([:name, :prompt, :project_id, :type])
    |> validate_inclusion(:type, ["scheduled", "webhook", "email"])
    |> maybe_generate_webhook_secret()
    |> validate_by_type()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:email_inbox_id)
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

      "email" ->
        changeset
        |> validate_required([:email_inbox_id])
        |> validate_non_empty_allowlist()

      _ ->
        changeset
    end
  end

  # An email trigger with an empty sender_allowlist would fire for mail from
  # ANY authenticated sender — refuse to create one. Entries that are blank
  # after trimming don't count, so `[""]` is rejected too.
  defp validate_non_empty_allowlist(changeset) do
    allowlist = get_field(changeset, :sender_allowlist) || []

    if Enum.any?(allowlist, fn entry -> is_binary(entry) and String.trim(entry) != "" end) do
      changeset
    else
      add_error(
        changeset,
        :sender_allowlist,
        "must contain at least one address or domain for an email trigger"
      )
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
