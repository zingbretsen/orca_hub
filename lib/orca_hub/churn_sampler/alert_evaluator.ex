defmodule OrcaHub.ChurnSampler.AlertEvaluator do
  @moduledoc """
  Condition evaluation for ORCAHUB3-44 Phase 2 worker alerts.

  `evaluate/3` is a self-contained step bolted onto `OrcaHub.ChurnSampler`'s
  existing 120s sweep (called right after each sampling pass, not fused
  into `ChurnSampler.run_sweep/1` itself — see that module's moduledoc).
  For every enabled `OrcaHub.AlertSubscriptions` row it:

    1. Resolves the watched set fresh — `session_ids` plus (if
       `watch_children`) the orchestrator's current non-archived children
       via `parent_session_id`, exactly like `SessionHeartbeat.Digest` —
       so children spawned after the subscription was set are picked up
       automatically.
    2. Evaluates every watched session regardless of its current status
       (NOT just the running ones `ChurnSampler` samples): `"stall"` only
       means something for a session stuck `running`, but `"churn"` and
       the other conditions are still meaningful for a watched session
       that's `idle`/`waiting`/`error` too. Activity/commit-info/churn are
       computed fresh here rather than reused from this tick's samples —
       a watched set is deliberately small ("cheap, they're few"), so the
       extra `git log` shell-outs this duplicates for sessions that
       happen to already be `running` (and thus already sampled this
       tick) are an accepted, bounded cost — see the moduledoc note in
       `OrcaHub.ChurnSampler`.
    3. Evaluates each configured condition (`"churn"`/`"stall"`/
       `"progress_stale"`/`"no_commit_for"` — see `evaluate_conditions/3`)
       and applies rising-edge + cooldown against `edge_state` (a
       `{subscription_id, session_id, condition} => %{state:,
       last_alerted_at:}` map): alerts only on a false->true transition,
       re-alerting only after `cooldown_seconds` has elapsed while still
       true.

  Returns `{alerts, new_edge_state}` — `alerts` is a list of
  `%{orchestrator_session_id:, session_id:, condition:, message:}` maps
  ready to deliver (delivery itself is the caller's job, via
  `OrcaHub.SessionHeartbeat.deliver_or_queue/2` — see `ChurnSampler`);
  keeping this module delivery-free is what makes it directly testable
  against fabricated `edge_state` without a live GenServer.

  `edge_state` is plain in-process data, not persisted — a deploy resets
  it, so at most one already-true condition can re-alert once immediately
  after a restart instead of waiting out its cooldown. Accepted per the
  issue: the DB-persisted piece is the subscription CONFIG, not this
  transient edge-tracking.
  """

  alias OrcaHub.{AlertSubscriptions, Cluster, Sessions}
  alias OrcaHub.Sessions.{Churn, ChurnDetail, FileSurgery, SurgeryAlertPolicy}

  @doc """
  Evaluates every enabled alert subscription and returns `{alerts,
  new_edge_state}`. `now` and `edge_state` are both explicit (rather than
  read from process state) so tests can drive rising-edge/cooldown
  transitions deterministically without waiting in real time or starting a
  GenServer.
  """
  def evaluate(subscriptions \\ nil, now \\ DateTime.utc_now(), edge_state \\ %{}) do
    subscriptions = subscriptions || AlertSubscriptions.list_enabled()

    Enum.reduce(subscriptions, {[], edge_state}, fn subscription, {alerts_acc, edge_acc} ->
      {alerts, edge_acc} = process_subscription(subscription, now, edge_acc)
      {alerts_acc ++ alerts, edge_acc}
    end)
  end

  # -------------------------------------------------------------------
  # Per-subscription evaluation
  # -------------------------------------------------------------------

  defp process_subscription(subscription, now, edge_state) do
    sessions =
      subscription
      |> resolve_watch_set()
      |> fetch_watched_sessions()

    if sessions == [] do
      {[], edge_state}
    else
      session_ids = Enum.map(sessions, & &1.id)
      activity_map = Sessions.activity_metadata(session_ids)
      commit_map = fetch_commit_info_for(sessions)
      pending_questions = fetch_pending_questions_for(session_ids)
      file_surgery_evidence = fetch_file_surgery_evidence_for(session_ids)

      Enum.reduce(sessions, {[], edge_state}, fn session, {alerts_acc, edge_acc} ->
        activity = Map.get(activity_map, session.id, %{})
        commit_info = Map.get(commit_map, session.id)
        pending_question_evidence = Map.get(pending_questions, session.id, nil)
        file_surgery = Map.get(file_surgery_evidence, session.id, nil)

        churn = Churn.assess(activity, session, commit_info, now, file_surgery)

        # ORCAHUB3-66: the ChurnDetail block is needed BEFORE the gate
        # decision (it is D6's input in SurgeryAlertPolicy) as well as for
        # the message body. Fetched at most once per session per tick and
        # threaded through both — nil here means "not needed yet", and
        # `fire/9` fetches it only if no gate ever asked for it.
        churn_detail =
          if surgery_gate_applies?(subscription.conditions || %{}, churn),
            do: ChurnDetail.fetch(session.id)

        conditions =
          evaluate_conditions(
            subscription.conditions || %{},
            session,
            activity,
            churn,
            %{pending_question: pending_question_evidence, file_surgery: file_surgery},
            churn_detail
          )

        {new_alerts, edge_acc} =
          Enum.reduce(conditions, {[], edge_acc}, fn {condition, value, discriminator},
                                                     {alerts2, edge2} ->
            apply_edge(
              subscription,
              session,
              condition,
              value,
              activity,
              churn,
              now,
              edge2,
              discriminator,
              churn_detail
            )
            |> case do
              {nil, edge3} -> {alerts2, edge3}
              {alert, edge3} -> {[alert | alerts2], edge3}
            end
          end)

        {alerts_acc ++ Enum.reverse(new_alerts), edge_acc}
      end)
    end
  end

  # Resolves the same way SessionHeartbeat.Digest.resolve_ids/3 does:
  # explicit session_ids plus (if watch_children) the orchestrator's
  # current non-archived children via parent_session_id, deduped.
  defp resolve_watch_set(subscription) do
    child_ids =
      if subscription.watch_children do
        Sessions.search_all_sessions(%{parent_session_id: subscription.orchestrator_session_id})
        |> Enum.map(& &1.id)
      else
        []
      end

    ((subscription.session_ids || []) ++ child_ids) |> Enum.uniq()
  end

  # Individual get_session/1 lookups (not a batch query) — mirrors
  # SessionHeartbeat.Digest.fetch_sessions/1 exactly, since a watch list is
  # the same "few, cheap" shape here.
  defp fetch_watched_sessions(ids) do
    ids
    |> Enum.map(&Sessions.get_session/1)
    |> Enum.filter(&(&1 && is_nil(&1.archived_at)))
  end

  # Dedupes by {runner_node, directory} so sessions sharing a working
  # directory only trigger one `git log` per directory — mirrors
  # ChurnSampler.fetch_all_commit_info/1 and
  # SessionHeartbeat.Digest.fetch_last_commits/1. Reuses Cluster's own
  # routing (Cluster.rpc/5) so an unreachable node is skipped rather than
  # raising, per the issue's cross-node design constraint.
  defp fetch_commit_info_for(sessions) do
    tagged =
      Enum.map(sessions, fn s -> {s.id, Cluster.runner_node_for(s) || node(), s.directory} end)

    commit_by_pair =
      tagged
      |> Enum.map(fn {_id, node, dir} -> {node, dir} end)
      |> Enum.uniq()
      |> Map.new(fn {node, dir} -> {{node, dir}, fetch_last_commit(node, dir)} end)

    Map.new(tagged, fn {id, node, dir} -> {id, commit_by_pair[{node, dir}]} end)
  end

  defp fetch_pending_questions_for(session_ids) do
    # Batch-fetch pending questions for all pi sessions only.
    # claude pending question check is done in-process via session.status == "waiting"
    pi_sessions = Enum.filter(session_ids, &valid_uuid?/1)

    try do
      Sessions.pending_questions_for(pi_sessions)
    rescue
      _ -> %{}
    end
  end

  defp fetch_file_surgery_evidence_for(session_ids) do
    # Batch-fetch FileSurgery evidence for all watched sessions in ONE query
    # Returns %{session_id => evidence_or_nil}, every id is guaranteed a key
    FileSurgery.fetch_many(session_ids, window_minutes: 10)
  end

  defp valid_uuid?(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp valid_uuid?(_), do: false

  defp fetch_last_commit(node, directory) do
    case Cluster.rpc(node, Sessions, :git_head_info, [directory]) do
      %{} = info -> info
      _ -> nil
    end
  end

  # -------------------------------------------------------------------
  # Conditions (item 4)
  # -------------------------------------------------------------------

  # Only a condition explicitly present in `conditions` is evaluated at
  # all — "progress_stale"/"no_commit_for"/"pending_question" are opt-in
  # (need an integer threshold for progress_stale/no_commit_for, boolean for
  # pending_question), "churn"/"stall" are boolean opt-in/opt-out.
  # The `evidence` argument is a map with:
  #   - :pending_question -> pi: %{id:, method:, title:, message:, options:} or nil;
  #     claude: checked via status == "waiting" in process
  #   - :file_surgery -> FileSurgery.detect/1 evidence or nil
  defp evaluate_conditions(conditions, session, activity, churn, evidence, churn_detail) do
    pending_question_evidence = Map.get(evidence, :pending_question, nil)

    conditions
    |> Enum.flat_map(fn
      {"churn", true} ->
        [{"churn", churn_alertable?(churn, session, churn_detail), nil}]

      {"stall", true} ->
        [{"stall", stall?(session, activity), nil}]

      {"progress_stale", minutes} when is_integer(minutes) ->
        [{"progress_stale", progress_stale?(churn, minutes), nil}]

      {"no_commit_for", minutes} when is_integer(minutes) ->
        [{"no_commit_for", no_commit_for?(session, activity, churn, minutes), nil}]

      {"pending_question", true} ->
        # For pending_question: value is boolean, discriminator is the question ID
        {question_id, is_pending} = pending_question(session, pending_question_evidence)
        [{"pending_question", is_pending, question_id}]

      _ ->
        []
    end)
  end

  # ORCAHUB3-66. `churn.churn_suspected` is `volumetric OR file_surgery` and
  # stays that way (the raw observation keeps flowing into churn_samples —
  # see Churn's moduledoc). What changes is what we ALERT on: the
  # file-surgery half now has to clear `SurgeryAlertPolicy`, while the
  # volumetric half is never suppressed by a surgery policy.
  defp churn_alertable?(churn, session, churn_detail) do
    churn.volumetric_churn_suspected or
      (churn.file_surgery_suspected and
         SurgeryAlertPolicy.alertable_for_session?(session, churn.file_surgery, churn_detail))
  end

  # The gate (and so the pre-fetched ChurnDetail) is only relevant when the
  # "churn" condition is watched AND file surgery is the thing driving it.
  defp surgery_gate_applies?(conditions, churn) do
    Map.get(conditions, "churn") == true and churn.file_surgery_suspected
  end

  defp stall?(session, activity) do
    session.status == "running" and (activity[:messages_15m] || 0) == 0 and
      (activity[:tool_calls_15m] || 0) == 0
  end

  # Only meaningful once progress has EVER been reported —
  # Churn.assess/4's minutes_since_progress_update is already nil when
  # progress_updated_at is nil, so this needs no separate "ever reported"
  # check.
  defp progress_stale?(churn, minutes) do
    case churn.minutes_since_progress_update do
      nil -> false
      m -> m > minutes
    end
  end

  defp no_commit_for?(session, activity, churn, minutes) do
    session.status == "running" and (activity[:tool_calls_15m] || 0) > 0 and
      (is_nil(churn.minutes_since_last_commit) or churn.minutes_since_last_commit > minutes)
  end

  # For pi sessions: evidence is %{id:, method:, title:, message:, options:} or nil
  # For claude sessions: checked via status == "waiting" in process
  # We check claude status in the session map directly, pi evidence from Sessions.pending_question/1
  defp pending_question(%{backend: "pi"}, evidence) do
    case evidence do
      nil -> {nil, false}
      %{id: id} -> {id, true}
    end
  end

  defp pending_question(%{backend: "claude", status: "waiting"}, _evidence),
    do: {:claude_waiting, true}

  defp pending_question(%{backend: "claude"}, _evidence), do: {nil, false}
  defp pending_question(_session, _evidence), do: {nil, false}

  # -------------------------------------------------------------------
  # Rising-edge + cooldown (item 5)
  # -------------------------------------------------------------------

  # For pending_question, value is boolean, discriminator is question ID (or nil for other conditions)
  defp apply_edge(
         subscription,
         session,
         condition,
         value,
         activity,
         churn,
         now,
         edge_state,
         discriminator,
         churn_detail
       ) do
    key = {subscription.id, session.id, condition}
    prior = Map.get(edge_state, key, %{state: false, last_alerted_at: nil})

    # Handle both plain boolean (churn/stall/etc) and tuple (pending_question) value
    # For pending_question, discriminator is the question ID; for others it's nil
    cond do
      value == false or value == {nil, false} ->
        # Condition is false - clear state, removing discriminator key if present
        {nil, Map.put(edge_state, key, Map.put(prior, :state, false))}

      not prior.state ->
        # First time seeing this condition - fire alert
        fire(
          subscription,
          session,
          condition,
          activity,
          churn,
          now,
          edge_state,
          key,
          discriminator,
          churn_detail
        )

      condition == "pending_question" and Map.get(prior, :discriminator, nil) != discriminator ->
        # For pending_question: new question ID - fresh rising edge, ignore cooldown
        fire(
          subscription,
          session,
          condition,
          activity,
          churn,
          now,
          edge_state,
          key,
          discriminator,
          churn_detail
        )

      cooldown_elapsed?(prior.last_alerted_at, subscription.cooldown_seconds, now) ->
        fire(
          subscription,
          session,
          condition,
          activity,
          churn,
          now,
          edge_state,
          key,
          discriminator,
          churn_detail
        )

      true ->
        {nil, edge_state}
    end
  end

  defp cooldown_elapsed?(nil, _cooldown_seconds, _now), do: true

  defp cooldown_elapsed?(last_alerted_at, cooldown_seconds, now),
    do: DateTime.diff(now, last_alerted_at, :second) >= (cooldown_seconds || 900)

  defp fire(
         subscription,
         session,
         condition,
         activity,
         churn,
         now,
         edge_state,
         key,
         discriminator,
         churn_detail
       ) do
    alert = %{
      orchestrator_session_id: subscription.orchestrator_session_id,
      session_id: session.id,
      condition: condition,
      message: build_message(session, condition, activity, churn, churn_detail)
    }

    edge_entry = %{state: true, last_alerted_at: now}

    # Only add discriminator key for pending_question condition
    edge_entry_with_discriminator =
      if condition == "pending_question" do
        Map.put(edge_entry, :discriminator, discriminator)
      else
        edge_entry
      end

    {alert, Map.put(edge_state, key, edge_entry_with_discriminator)}
  end

  # -------------------------------------------------------------------
  # Message formatting (item 6/7/8)
  # -------------------------------------------------------------------

  @suggested_action "Suggested: peek with get_session_tail; redirect with send_message_to_session; " <>
                      "answer dialogs with answer_session_question."

  # ORCAHUB3-66 message order. The corroborating ChurnDetail LEADS; the
  # flagged shell command FOLLOWS it as an advisory footnote. That is the
  # inverse of the original layout and it is measured, not taste: of the
  # three hand-labelled true positives in `churn_alert_precision.md`, TWO
  # were true because of the `Repeated calls:` block the alert carried
  # alongside the file-surgery sentence, not because of the sentence itself.
  # The old format led with the weakest evidence.
  defp build_message(session, condition, activity, churn, churn_detail) do
    title = session.title || "session #{String.slice(session.id, 0, 8)}"

    detail = churn_detail || ChurnDetail.fetch(session.id)
    detail_block = format_detail(detail)

    header =
      "[Worker alert] #{condition} on #{title} (#{session.id}): " <>
        metric_line(condition, session, activity, churn, detail)

    [header, detail_block, surgery_block(condition, churn, detail_block), @suggested_action]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n\n")
  end

  defp metric_line("churn", _session, _activity, churn, detail) do
    calls = churn.tool_calls_15m || 0
    ratio = churn.repetition_ratio_15m || 0.0

    extra =
      [
        commit_clause(churn, detail),
        churn.minutes_since_progress_update &&
          "progress stale #{churn.minutes_since_progress_update}m"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(", ")

    base = "#{calls} calls/15m, #{round(ratio * 100)}% repeats"
    if extra != "", do: base <> ", " <> extra, else: base
  end

  defp metric_line("stall", _session, _activity, _churn, _detail) do
    "status running, 0 messages/0 tool calls in the last 15m"
  end

  defp metric_line("progress_stale", session, _activity, churn, _detail) do
    phase =
      if present?(session.progress_phase), do: " (phase: #{session.progress_phase})", else: ""

    "progress last updated #{churn.minutes_since_progress_update}m ago#{phase}"
  end

  defp metric_line("no_commit_for", _session, _activity, churn, _detail) do
    calls = churn.tool_calls_15m || 0

    case churn.minutes_since_last_commit do
      nil -> "#{calls} tool calls/15m, no commit observed yet"
      age -> "#{calls} tool calls/15m, last commit #{age}m ago"
    end
  end

  defp metric_line("pending_question", session, _activity, _churn, _detail) do
    cond do
      session.backend == "pi" ->
        case Sessions.pending_question(session.id) do
          nil ->
            "no pending dialog"

          %{id: id, method: method} ->
            "pi session blocked on dialog (id: #{id}, method: #{method}) - answer with answer_session_question"
        end

      session.backend == "claude" ->
        "claude session blocked on dialog (status: waiting) - send user message to answer"

      true ->
        "pending dialog (#{session.backend})"
    end
  end

  # Advisory, not a diagnosis. The old wording ("worker rebuilding X from
  # shell fragments") asserted a conclusion the evidence does not support —
  # 34 of 39 hand-labelled alerts were a deliberate, successful, one-shot
  # shell edit. The paired/unpaired "confidence" language is gone entirely:
  # `paired_with_failed_edit` has never once been true in production, so
  # every alert ever delivered was labelled "lower confidence" against a
  # high-confidence branch that cannot fire. The boolean stays in the
  # evidence map for mining; it is just no longer printed as a claim.
  defp surgery_block("churn", churn, detail_block) do
    case churn.file_surgery do
      %{path: path, command: cmd, kind: kind} ->
        basis =
          if detail_block in [nil, ""],
            do: "no corroborating detail in this window",
            else: "judge from the detail above, not from this line"

        "Advisory: wrote #{path} from the shell (#{kind}) — #{basis}.\nCommand: #{cmd}"

      _ ->
        nil
    end
  end

  defp surgery_block(_condition, _churn, _detail_block), do: nil

  # "no commit Nm" is only evidence of anything if the session was editing
  # the repo at all. 80 of 229 production file-surgery alerts carried this
  # clause on deploy/gate/cleanup/measurement workers that do not commit by
  # design. When there are no repo edits in the window, say that instead of
  # implying a missing commit. (This is the CLAUSE only — the `no_commit_for`
  # CONDITION is untouched.)
  defp commit_clause(_churn, %{top_edited_files: []}), do: "no repo edits in window"

  defp commit_clause(churn, _detail),
    do: churn.minutes_since_last_commit && "no commit #{churn.minutes_since_last_commit}m"

  defp present?(str), do: is_binary(str) and String.trim(str) != ""

  defp format_detail(%{
         top_edited_files: files,
         top_repeated_signatures: signatures,
         failing_tests: failing_tests
       }) do
    # Repeated calls first: it is the block that actually carried the signal
    # in 2 of 3 hand-labelled true positives (churn_alert_precision.md §C.3).
    [
      format_signatures(signatures),
      format_edited_files(files),
      format_failing_tests(failing_tests)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join("\n")
  end

  defp format_edited_files([]), do: nil

  defp format_edited_files(files) do
    "Top edited files: " <>
      Enum.map_join(files, ", ", fn %{path: path, count: count} -> "#{path} (#{count})" end)
  end

  defp format_signatures([]), do: nil

  defp format_signatures(signatures) do
    "Repeated calls: " <>
      Enum.map_join(signatures, "; ", fn %{tool: tool, count: count, sample: sample} ->
        "#{count}x #{tool}: #{sample}"
      end)
  end

  defp format_failing_tests([]), do: nil

  defp format_failing_tests(entries) do
    "Failing tests: " <>
      Enum.map_join(entries, " | ", fn %{summary: summary, failing_test_names: names} ->
        if names == [], do: summary, else: "#{summary} — #{Enum.join(names, "; ")}"
      end)
  end
end
