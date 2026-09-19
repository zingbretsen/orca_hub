defmodule OrcaHub.Sessions.EditFailure do
  @moduledoc """
  Qualitative distress detector for "the worker cannot land an edit"
  (ORCAHUB3-63 §1): repeated `Edit`/`Write`/`MultiEdit` FAILURES on ONE
  file with NO successful edit to that file in between.

  This is deliberately separate from `OrcaHub.Sessions.Churn` (volumetric:
  call rate + repetition ratio) and from `OrcaHub.Sessions.FileSurgery`
  (a worker rebuilding a tracked file from shell fragments). It is
  ADDITIVE COVERAGE, not a fallback for either:

  - Volumetrically it is INVISIBLE. The motivating live example was two
    IDENTICAL failed `Edit` calls trying to CREATE a file that did not
    exist yet (`Edit` cannot create) at `tool_calls_15m = 4`, with
    `churn_suspected = false`. Any design that only fires at high volume
    is wrong for this signal, so `detect/1` consults NO rate or
    repetition condition — only the failure streak itself.
  - It does not overlap the file-surgery population. Across all 229
    historical file-surgery alert windows (`churn_alert_precision.md`
    §D.4), failed editor calls number 0 in 223 windows, 1 in 5 and 2 in 1,
    and none of the three hand-labelled true positives has a single one.
    "Worker cannot land an edit" and "worker writes a file from the shell"
    are DISJOINT populations in that corpus. Nothing suppressed by
    ORCAHUB3-66 is recovered here, and nothing here should be justified by
    that suppression.

  ## Threshold: >= 2 failures on one path, no success between

  Measured, not guessed — `churn_signal_mining.md` ranked candidate signal
  #3, "repeated `Edit`/`Write`/`MultiEdit` failures on the same file, no
  successful edit on that file in between (>= 2, 30m)", at **P=0.89 /
  R=0.08** pooled (claude 1.00/0.006, pi+codex 0.88/0.18) over 295
  labelled intervention events and 92 clean-completion controls. That
  operating point IS the `>= 2` rule at a 30-minute window, so the module
  ships exactly the rule that was scored.

  One failure is not a signal: a single `Edit` that misses on a stale
  `old_string` and is retried successfully is ordinary, healthy behaviour
  and occurs constantly in clean control sessions. The second failure with
  no success in between is where the population separates. Raising the bar
  to 3 would trade away recall that is already only 0.08 for precision
  that is already 0.89 — the wrong direction for an ADVISORY alert an
  orchestrator judges. Expect it to fire RARELY, and almost never on
  claude (1 true positive in 170 claude events); that is the measured
  shape of the signal, not a defect.

  **Reset on success is the whole point.** A worker that fails, recovers,
  and later fails again is not stuck, so any successful editor call on a
  path clears that path's streak. Only the CURRENT unbroken streak counts.

  ## Evidence

      %{path: "lib/orca_hub/foo.ex",
        failure_count: 2,
        tools: ["Edit"],
        identical_calls: true,
        last_error: "File does not exist."}

  `identical_calls` is carried because byte-identical retries are a much
  stronger distress signal than two different attempts — the ORCAHUB3-63
  motivating case retried the exact same failing `Edit` verbatim, which is
  a model that has stopped incorporating the error text at all.

  Computed from the messages table's assistant `tool_use` blocks paired
  with their `tool_result` blocks (mirrors `OrcaHub.Sessions.FileSurgery`'s
  extraction shape exactly — see its moduledoc). `detect/1` is pure and
  never raises.
  """

  import Ecto.Query

  require Logger

  alias OrcaHub.Repo
  alias OrcaHub.Sessions.Message

  @default_window_minutes 30
  @sweep_window_minutes 10

  @edit_tool_names ~w(Edit Write MultiEdit)

  @failure_threshold 2
  @error_text_limit 300

  @doc """
  Fetches `session_id`'s messages from the last `window_minutes` (default
  #{@default_window_minutes}, the window the signal was measured at) and
  runs `detect/1` over them.

  Never raises — an invalid `session_id` or a DB failure is logged and
  returns `nil`, matching `detect/1`'s own non-raising guarantee.
  """
  def fetch(session_id, opts \\ []) do
    window_minutes = Keyword.get(opts, :window_minutes, @default_window_minutes)
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-window_minutes * 60, :second)

    messages =
      from(m in Message,
        where: m.session_id == ^session_id and m.inserted_at >= ^cutoff,
        order_by: [asc: m.inserted_at]
      )
      |> Repo.all()

    detect(messages)
  rescue
    e ->
      Logger.warning(
        "EditFailure.fetch/2 failed for session #{inspect(session_id)}: #{Exception.message(e)}"
      )

      nil
  end

  @doc """
  Batched fetch for many sessions in ONE query — the hot path for a
  per-watched-session sweep (default window #{@sweep_window_minutes}
  minutes, shorter than `fetch/2`'s, since this runs on a short cadence and
  must stay cheap).

  Returns `%{session_id => evidence_or_nil}`. Every id in `session_ids` is
  guaranteed to be a key of the result — a session with no messages (or no
  match) in the window maps to `nil`, it is never simply absent, and that
  guarantee holds on the FAILURE PATH too: a caller reasonably reads a
  missing key as "not computed yet" and a `nil` value as "no evidence", so
  returning `%{}` under failure would silently change that meaning rather
  than obviously breaking.

  An invalid `session_id` (fails to parse as a UUID) is filtered out BEFORE
  the batch query rather than left to raise inside it — since this one
  query covers the whole watched set at once, a single bad id must never
  poison every OTHER session's result. `detect/1` is already per-session
  safe (`safely/1` wraps it, run once per group), so the query is the only
  all-or-nothing step in this function; a genuine DB failure past the
  filter is still caught by the outer rescue as a backstop, mapping every
  requested id to `nil`.
  """
  def fetch_many(session_ids, opts \\ []) when is_list(session_ids) do
    window_minutes = Keyword.get(opts, :window_minutes, @sweep_window_minutes)
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-window_minutes * 60, :second)

    {valid_ids, invalid_ids} = Enum.split_with(session_ids, &valid_uuid?/1)

    if invalid_ids != [] do
      Logger.warning(
        "EditFailure.fetch_many/2 dropped invalid session ids: #{inspect(invalid_ids)}"
      )
    end

    messages =
      from(m in Message,
        where: m.session_id in ^valid_ids and m.inserted_at >= ^cutoff,
        order_by: [asc: m.inserted_at]
      )
      |> Repo.all()

    evidence_by_session =
      messages
      |> Enum.group_by(& &1.session_id)
      |> Map.new(fn {session_id, msgs} -> {session_id, detect(msgs)} end)

    session_ids
    |> Map.new(&{&1, nil})
    |> Map.merge(evidence_by_session)
  rescue
    e ->
      Logger.warning(
        "EditFailure.fetch_many/2 failed for #{length(session_ids)} session(s): #{Exception.message(e)}"
      )

      Map.new(session_ids, &{&1, nil})
  end

  defp valid_uuid?(id) when is_binary(id) do
    case Ecto.UUID.cast(id) do
      {:ok, _} -> true
      :error -> false
    end
  end

  defp valid_uuid?(_), do: false

  @doc """
  Pure detection over an already-fetched, oldest-first list of message
  structs/maps (each needs only a `data` field/key) — mirrors
  `FileSurgery.detect/1`'s seam.

  Returns the streak whose MOST RECENT failure is newest, as an evidence
  map:

      %{path: String.t(),
        failure_count: pos_integer(),
        tools: [String.t()],
        identical_calls: boolean(),
        last_error: String.t() | nil}

  or `nil` when no path has reached #{@failure_threshold} failures with no
  successful edit in between. Never raises.

  Field meanings, for the caller that renders this:

    * `path` — the `input.file_path` of the failing calls, compared
      VERBATIM. Two spellings of the same file (absolute vs relative) are
      two paths and do not combine; that matches `FileSurgery`'s pairing
      check and keeps the reported path exactly what the worker typed.
    * `failure_count` — length of the CURRENT unbroken failure streak on
      that path, not the total failures in the window.
    * `tools` — which editor tools failed, distinct, in first-failure
      order (e.g. `["Edit"]`, or `["Edit", "Write"]` when the worker
      escalated).
    * `identical_calls` — every failed call in the streak had a
      byte-identical `{name, input}`: the worker retried verbatim instead
      of reacting to the error.
    * `last_error` — the newest failing `tool_result`'s text, trimmed to
      #{@error_text_limit} characters, or `nil` when the result carried no
      readable text.

  A call with NO matching `tool_result` in the window (still in flight, or
  its result fell outside the window) is treated as UNKNOWN: it neither
  counts as a failure nor resets the streak. Counting an unknown as a
  success would silently erase a real streak whenever a window boundary
  landed between a call and its result.
  """
  def detect(messages) when is_list(messages) do
    safely(fn ->
      results = build_result_index(messages)

      messages
      |> Enum.flat_map(&tool_use_blocks/1)
      |> Enum.with_index()
      |> Enum.reduce(%{}, &track_editor_call(&1, &2, results))
      |> best_streak()
      |> evidence()
    end)
  end

  def detect(_), do: nil

  defp safely(fun) do
    fun.()
  rescue
    _ -> nil
  end

  # -------------------------------------------------------------------
  # Streak tracking
  # -------------------------------------------------------------------

  # streaks :: %{path => %{failures: [failure], last_index: non_neg_integer}}
  # A failure is %{name: ..., input: ..., error: ...}, oldest-first;
  # `last_index` is the position of the newest failure in the window's
  # tool-call sequence, used only to pick which streak to report.
  defp track_editor_call({block, index}, streaks, results) do
    with %{"name" => name, "input" => %{"file_path" => path} = input}
         when name in @edit_tool_names and is_binary(path) <- block,
         result when result != :unknown <- call_outcome(block, results) do
      case result do
        {:error, text} ->
          failure = %{name: name, input: input, error: text}

          Map.update(
            streaks,
            path,
            %{failures: [failure], last_index: index},
            fn streak ->
              %{streak | failures: streak.failures ++ [failure], last_index: index}
            end
          )

        :ok ->
          # Reset on success — "no successful edit in between" is the
          # whole signal. A worker that fails, recovers, and later fails
          # again is not stuck.
          Map.delete(streaks, path)
      end
    else
      _ -> streaks
    end
  end

  defp call_outcome(%{"id" => id}, results) when is_binary(id) do
    case Map.fetch(results, id) do
      {:ok, {true, text}} -> {:error, text}
      {:ok, {false, _text}} -> :ok
      :error -> :unknown
    end
  end

  defp call_outcome(_, _), do: :unknown

  # The streak whose newest failure is newest — mirrors FileSurgery
  # reporting the most recent match rather than the "biggest".
  defp best_streak(streaks) do
    streaks
    |> Enum.filter(fn {_path, %{failures: failures}} ->
      length(failures) >= @failure_threshold
    end)
    |> Enum.max_by(fn {_path, %{last_index: index}} -> index end, fn -> nil end)
  end

  defp evidence(nil), do: nil

  defp evidence({path, %{failures: failures}}) do
    %{
      path: path,
      failure_count: length(failures),
      tools: failures |> Enum.map(& &1.name) |> Enum.uniq(),
      identical_calls: identical_calls?(failures),
      last_error: failures |> List.last() |> Map.get(:error)
    }
  end

  defp identical_calls?(failures) do
    failures
    |> Enum.uniq_by(&{&1.name, &1.input})
    |> length()
    |> Kernel.==(1)
  end

  # -------------------------------------------------------------------
  # Shared message parsing (mirrors FileSurgery / ChurnDetail)
  # -------------------------------------------------------------------

  # tool_use_id -> {is_error?, trimmed error text}, from tool_result blocks
  # across the whole window (a result lands in the message after its call).
  defp build_result_index(messages) do
    messages
    |> Enum.flat_map(&tool_result_blocks/1)
    |> Enum.reduce(%{}, fn
      %{"tool_use_id" => id} = block, acc when is_binary(id) ->
        Map.put(acc, id, {block["is_error"] == true, result_text(block["content"])})

      _, acc ->
        acc
    end)
  end

  defp result_text(content) when is_binary(content), do: trim_error(content)

  defp result_text(content) when is_list(content) do
    content
    |> Enum.filter(&is_map/1)
    |> Enum.map(& &1["text"])
    |> Enum.filter(&is_binary/1)
    |> Enum.join("\n")
    |> trim_error()
  end

  defp result_text(_), do: nil

  defp trim_error(text) do
    case String.trim(text) do
      "" -> nil
      trimmed -> String.slice(trimmed, 0, @error_text_limit)
    end
  end

  defp tool_use_blocks(%{data: data}) do
    data
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_use"))
  end

  defp tool_use_blocks(_), do: []

  defp tool_result_blocks(%{data: data}) do
    data
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_result"))
  end

  defp tool_result_blocks(_), do: []
end
