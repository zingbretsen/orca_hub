defmodule OrcaHub.Triggers.Trigger do
  @moduledoc "Schema for a scheduled, one-off, webhook, or inbound-email trigger."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "triggers" do
    field :name, :string
    field :prompt, :string
    field :type, :string, default: "scheduled"
    field :cron_expression, :string
    # type: "once" only. The single UTC instant the trigger fires at. The DB
    # row is the source of truth (OrcaHub.OneOffTriggerSweep polls for due,
    # still-enabled ones), not an in-memory Quantum job — so a months-out
    # reminder survives every deploy in between. TriggerExecutor disables
    # the trigger in the same write that stamps last_fired_at, which is what
    # makes it fire once.
    field :run_at, :utc_datetime
    # Calendar-style end conditions ("ends after N runs" / "ends on date"),
    # enforced by OrcaHub.TriggerExecutor.execute/1 — i.e. for scheduled and
    # once triggers (webhook/email fires go through execute_payload/2 and are
    # not counted). run_count counts SUCCESSFUL fires only; a skipped fire
    # (node unavailable) doesn't count. The trigger auto-disables when
    # run_count reaches max_runs, or when its next fire would land after
    # ends_at. nil = never ends. A once trigger is max_runs 1 (forced below).
    field :max_runs, :integer
    field :run_count, :integer, default: 0
    field :ends_at, :utc_datetime
    field :webhook_secret, :string
    field :reuse_session, :boolean, default: false
    field :archive_on_complete, :boolean, default: false
    field :enabled, :boolean, default: true
    # Nullable override of the default session scope rule for automatic
    # memory extraction (OrcaHub.MemoryExtraction.in_scope?/1), applied to
    # every session this trigger spawns — nil inherits the normal rule,
    # true/false forces it. See sessions.memory_extract for the per-session
    # equivalent this mirrors.
    field :memory_extract, :boolean
    # Per-trigger MCP tool restrictions, stamped onto every session this
    # trigger spawns (OrcaHub.TriggerExecutor.create_new_session/1) — the
    # declarative, ENFORCED replacement for a "you may NEVER call X" English
    # paragraph in the prompt, which a model is free to ignore. Identical
    # shape and semantics to sessions.tool_allowlist/tool_denylist, since
    # that is exactly where they end up: nil OR [] mean "no restriction" on
    # EITHER side (an explicit deny-all is `tool_denylist: ["*"]`), deny wins
    # over allow, and entries are exact raw MCP tool names or anchored
    # `*`-globs, case-sensitive. See OrcaHub.ToolPolicy.
    #
    # LIMITATION (same as memory_extract): these are stamped only on a
    # session this trigger CREATES. A `reuse_session: true` trigger keeps
    # messaging the session it made earlier, so editing these lists does NOT
    # retroactively re-scope an already-running reused session — the change
    # takes effect on the next session the trigger creates.
    field :tool_allowlist, {:array, :string}
    field :tool_denylist, {:array, :string}
    # An operator-authored shell script run on the session's runner node, in
    # the session's directory, before the prompt is delivered — on EVERY
    # firing, including a reuse_session firing (it is a "gather current state
    # before this run" hook, not one-time provisioning). Its combined
    # output/exit code/duration are prepended to the prompt in a
    # <setup_script> block. nil/blank means no script. A non-zero exit or a
    # timeout does NOT abort the firing. Never receives any webhook/email
    # payload data — see OrcaHub.Triggers.SetupScript.
    field :setup_script, :string
    field :setup_timeout_seconds, :integer, default: 120
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

  @types ["scheduled", "once", "webhook", "email"]

  def types, do: @types

  def changeset(trigger, attrs) do
    trigger
    |> cast(attrs, [
      :name,
      :prompt,
      :type,
      :cron_expression,
      :run_at,
      :max_runs,
      :run_count,
      :ends_at,
      :webhook_secret,
      :reuse_session,
      :archive_on_complete,
      :enabled,
      :memory_extract,
      :tool_allowlist,
      :tool_denylist,
      :setup_script,
      :setup_timeout_seconds,
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
    |> validate_inclusion(:type, types())
    |> validate_setup_timeout()
    |> validate_number(:max_runs, greater_than: 0)
    |> validate_number(:run_count, greater_than_or_equal_to: 0)
    |> validate_future(:ends_at)
    |> maybe_generate_webhook_secret()
    |> validate_by_type()
    |> foreign_key_constraint(:project_id)
    |> foreign_key_constraint(:email_inbox_id)
    |> unique_constraint(:webhook_secret)
  end

  # The setup script blocks the firing while it runs, so an unbounded (or
  # absurd) timeout would wedge the trigger rather than bound it. nil is
  # allowed and means "use the default" — see
  # OrcaHub.Triggers.SetupScript.timeout_seconds/1.
  defp validate_setup_timeout(changeset) do
    case get_field(changeset, :setup_timeout_seconds) do
      nil ->
        changeset

      _ ->
        validate_number(changeset, :setup_timeout_seconds,
          greater_than: 0,
          less_than_or_equal_to: 3600
        )
    end
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

      "once" ->
        changeset
        |> validate_required([:run_at])
        |> validate_future(:run_at)
        |> put_change(:max_runs, 1)
        |> reset_run_count_on_reschedule()

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

  # Only a run_at/ends_at being SET (create, or an edit that moves it) must be
  # in the future — the executor's own post-fire update leaves a past value in
  # place and must still validate.
  defp validate_future(changeset, field) do
    case get_change(changeset, field) do
      %DateTime{} = value ->
        if DateTime.compare(value, DateTime.utc_now()) == :gt do
          changeset
        else
          add_error(changeset, field, "must be in the future")
        end

      _ ->
        changeset
    end
  end

  # Moving an already-fired one-off's run_at reschedules it: clear its count
  # so it can fire again (re-enabling WITHOUT moving run_at leaves it ended).
  defp reset_run_count_on_reschedule(changeset) do
    if changeset.data.id && get_change(changeset, :run_at) do
      put_change(changeset, :run_count, 0)
    else
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
