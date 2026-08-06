defmodule OrcaHub.Issues do
  @moduledoc """
  Context for issues — durable, agent-usable work items (issues_spec.md).

  Originally a minimal reintroduction backing just `file_feature_request`;
  this module now carries the full spec: per-project short-key allocation
  (§3.2), the three-form id resolution used by every tool that accepts an
  issue id (§3.2.4), title-similarity dedup generalized to `(project_id,
  kind)` (§7), the live/frozen "attempt" projection (§3.5/§4.3), and the
  close-time commit/attempt freeze (§4.2/§4.3) plus the reopen
  preserve-then-clear sequence (§3.5.1).

  ## Backward-compatible vs. new API

  `create_issue/1`, `get_issue/1,!`, `list_open_issues_for_project/1`,
  `list_issues_for_project/1`, `list_issues_by_id_prefix/1`,
  `list_issues/0`, `update_issue/2`, `append_note/2`, `close_issue/1`, and
  `reopen_issue/1` all keep their original signature/behavior — they're
  relied on by `OrcaHub.MCP.Tools.FeatureRequests` and `IssueLive`
  (both still on the pre-spec contract; migrating them is Phase 2/a UI
  follow-up, not this module's job). `close_issue/1`/`reopen_issue/1` in
  particular do NOT freeze commits/attempts or archive anything — they're
  the old, unconditional "just flip status" behavior, left alone on
  purpose.

  The spec's actual close/reopen semantics live in the new `close_issue/2`
  and `reopen_issue/2` (different arity, so both old and new call sites
  compile side by side) — see their docs.
  """

  import Ecto.Query
  alias OrcaHub.{Issues.Issue, Projects.Project, Repo, Sessions, Sessions.Session}

  # ── create ────────────────────────────────────────────────────────────

  @doc """
  Creates an issue. When `attrs` includes a `project_id` (almost always),
  atomically allocates the next `key_number` for that project via a
  row-locking `Repo.update_all` increment (issues_spec.md §3.2.2),
  wrapped in the same transaction as the insert so a changeset validation
  failure rolls the increment back too. Gaps in `key_number` are
  otherwise an accepted, expected outcome — see §3.2.2 — not something
  this function tries to prevent beyond that transactional rollback.

  Without a `project_id`, inserts with `key_number: nil` (no counter to
  allocate against) — same as today's keyless-issue behavior.
  """
  def create_issue(attrs) do
    case fetch_project_id(attrs) do
      nil -> %Issue{} |> Issue.changeset(attrs) |> Repo.insert()
      project_id -> create_issue_with_key(project_id, attrs)
    end
  end

  defp fetch_project_id(attrs), do: attrs[:project_id] || attrs["project_id"]

  defp create_issue_with_key(project_id, attrs) do
    Repo.transaction(fn ->
      case allocate_key_number(project_id) do
        {:ok, key_number} ->
          attrs
          |> put_key_number(key_number)
          |> insert_issue()

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  defp allocate_key_number(project_id) do
    # NOTE: issues_spec.md §3.2.2's snippet uses `returning: [:issue_counter]`
    # alone — on this Ecto/ecto_sql version that's a no-op (`update_all`'s
    # second return element is `nil` unless the query itself carries a
    # `select`; `returning:` isn't consulted for update_all the way it is
    # for insert/delete). An explicit `select` is what actually gets the
    # post-increment value back.
    query =
      from p in Project,
        where: p.id == ^project_id,
        select: p.issue_counter

    case Repo.update_all(query, inc: [issue_counter: 1]) do
      {1, [key_number]} -> {:ok, key_number}
      {0, _} -> {:error, :project_not_found}
    end
  end

  defp put_key_number(attrs, key_number) do
    if Map.has_key?(attrs, "project_id") do
      Map.put(attrs, "key_number", key_number)
    else
      Map.put(attrs, :key_number, key_number)
    end
  end

  defp insert_issue(attrs) do
    case %Issue{} |> Issue.changeset(attrs) |> Repo.insert() do
      {:ok, issue} -> issue
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # ── read ──────────────────────────────────────────────────────────────

  def get_issue(id), do: Repo.get(Issue, id)

  def get_issue!(id), do: Repo.get!(Issue, id)

  @doc "Non-terminal (open/in_progress) issues for a project, most recently filed first."
  def list_open_issues_for_project(project_id) do
    Repo.all(
      from i in Issue,
        where: i.project_id == ^project_id and i.status not in ["closed", "abandoned"],
        order_by: [desc: i.inserted_at]
    )
  end

  @doc "Every issue for a project regardless of status, most recently filed first."
  def list_issues_for_project(project_id) do
    Repo.all(
      from i in Issue,
        where: i.project_id == ^project_id,
        order_by: [desc: i.inserted_at]
    )
  end

  @doc """
  Issues whose id, cast to text, starts with `prefix` — backs short/prefix id
  resolution (see `resolve_id/1`). `prefix` should already be a validated hex
  string (with UUID dashes reinserted at canonical positions as needed) by
  the caller.
  """
  def list_issues_by_id_prefix(prefix) do
    Repo.all(from i in Issue, where: fragment("?::text LIKE ?", i.id, ^"#{prefix}%"))
  end

  @doc "Every issue, open first, newest first within each group."
  def list_issues do
    Repo.all(
      from i in Issue,
        order_by: [desc: fragment("? = 'open'", i.status), desc: i.inserted_at]
    )
  end

  @doc """
  Filtered issue listing — backs the future `list_issues` MCP tool
  (issues_spec.md §6.2). `opts` (map or keyword list, all keys optional):

    * `:status` - `"open"` (default), `"in_progress"`, `"closed"`,
      `"abandoned"`, or `"all"`
    * `:kind` - `"task"`, `"feature_request"`, or `"all"` (default)
    * `:project_id` - scope to one project (omit for all projects)
    * `:created_by_session_id` - only issues created by that session
      (backs the tool surface's `mine: true`, which resolves the
      caller's own session id before calling this)
    * `:query` - case-insensitive title substring filter
    * `:limit` - default 50
  """
  def list_issues(opts) do
    opts = Map.new(opts)

    Issue
    |> filter_by_status_opt(Map.get(opts, :status))
    |> filter_by_kind_opt(Map.get(opts, :kind))
    |> filter_by_project_opt(Map.get(opts, :project_id))
    |> filter_by_creator_opt(Map.get(opts, :created_by_session_id))
    |> filter_by_query_opt(Map.get(opts, :query))
    |> order_by([i], desc: i.inserted_at)
    |> limit(^Map.get(opts, :limit, 50))
    |> Repo.all()
  end

  defp filter_by_status_opt(query, status) when status in [nil, "open"],
    do: where(query, [i], i.status == "open")

  defp filter_by_status_opt(query, "all"), do: query
  defp filter_by_status_opt(query, status), do: where(query, [i], i.status == ^status)

  defp filter_by_kind_opt(query, kind) when kind in [nil, "all"], do: query
  defp filter_by_kind_opt(query, kind), do: where(query, [i], i.kind == ^kind)

  defp filter_by_project_opt(query, nil), do: query

  defp filter_by_project_opt(query, project_id),
    do: where(query, [i], i.project_id == ^project_id)

  defp filter_by_creator_opt(query, nil), do: query

  defp filter_by_creator_opt(query, session_id),
    do: where(query, [i], i.created_by_session_id == ^session_id)

  defp filter_by_query_opt(query, q) when is_binary(q) and q != "" do
    where(query, [i], ilike(i.title, ^"%#{q}%"))
  end

  defp filter_by_query_opt(query, _), do: query

  # ── id resolution (§3.2.4) ───────────────────────────────────────────

  @full_uuid_regex ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
  @rendered_key_regex ~r/^([A-Za-z][A-Za-z0-9]{1,9})-([0-9]+)$/
  @hex_only_regex ~r/^[0-9a-f]+$/i

  @doc """
  Resolves an issue id string via the three forms from issues_spec.md
  §3.2.4, tried in order:

    1. Full UUID — exact match on `issues.id`.
    2. Rendered key (e.g. `"ORCA-142"`) — split into `{prefix, number}`,
       resolved case-insensitively against a real `projects.key_prefix`.
       Only matches if a project with that exact prefix actually exists;
       otherwise falls through to form 3 (this is what keeps the pattern
       from colliding with a hex UUID prefix that happens to contain a
       dash — see §3.2.4).
    3. Hex prefix (>= 8 hex chars, dashes optional) — disambiguated the
       same way the old `fetch_agent_issue_by_prefix/1` was (an error
       listing every match if ambiguous).

  Returns `{:ok, issue}` or `{:error, message}` with a friendly,
  ready-to-surface error string.
  """
  def resolve_id(id) when is_binary(id) do
    cond do
      Regex.match?(@full_uuid_regex, id) ->
        resolve_by_uuid(id)

      match = Regex.run(@rendered_key_regex, id) ->
        case resolve_by_key(match) do
          {:error, :no_such_project} -> resolve_by_hex_prefix(id)
          result -> result
        end

      true ->
        resolve_by_hex_prefix(id)
    end
  end

  def resolve_id(_), do: {:error, "Issue id must be a string."}

  defp resolve_by_uuid(id) do
    case get_issue(id) do
      nil -> {:error, "No issue found with id #{id}."}
      issue -> {:ok, issue}
    end
  end

  defp resolve_by_key([_full, prefix, number_str]) do
    query =
      from p in Project,
        where: fragment("upper(?) = upper(?)", p.key_prefix, ^prefix),
        limit: 1

    case Repo.one(query) do
      nil ->
        {:error, :no_such_project}

      %Project{id: project_id} ->
        number = String.to_integer(number_str)

        case Repo.get_by(Issue, project_id: project_id, key_number: number) do
          nil -> {:error, "No issue found with key #{String.upcase(prefix)}-#{number}."}
          issue -> {:ok, issue}
        end
    end
  end

  defp resolve_by_hex_prefix(id) do
    hex = String.replace(id, "-", "")

    if Regex.match?(@hex_only_regex, hex) and String.length(hex) in 8..32 do
      hex
      |> String.downcase()
      |> uuid_prefix_pattern()
      |> list_issues_by_id_prefix()
      |> resolve_prefix_matches(id)
    else
      {:error,
       "\"#{id}\" isn't a valid issue id — pass a short key (e.g. ORCA-142), a full id, or " <>
         "a hex prefix of at least 8 characters."}
    end
  end

  defp resolve_prefix_matches([issue], _id), do: {:ok, issue}

  defp resolve_prefix_matches([], id), do: {:error, "No issue found with id starting \"#{id}\"."}

  defp resolve_prefix_matches(issues, id) do
    matches = Enum.map_join(issues, ", ", &"#{&1.id} (#{&1.title})")

    {:error,
     "Multiple issues match id prefix \"#{id}\": #{matches}. Use a longer prefix, the full " <>
       "id, or the issue's key."}
  end

  # Splits a hex prefix at canonical UUID group boundaries (8-4-4-4-12) and
  # rejoins with dashes, so a dash-free short id and a longer dashed one
  # both produce a valid `id::text LIKE` pattern regardless of whether the
  # caller included dashes.
  defp uuid_prefix_pattern(hex) do
    {a, rest} = String.split_at(hex, 8)
    {b, rest} = String.split_at(rest, 4)
    {c, rest} = String.split_at(rest, 4)
    {d, rest} = String.split_at(rest, 4)
    {e, _} = String.split_at(rest, 12)

    [a, b, c, d, e]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("-")
  end

  # ── key rendering ─────────────────────────────────────────────────────

  @doc "Renders an issue's short key (e.g. \"ORCA-142\"), or `nil` if it has none yet."
  def render_key(%Issue{key_number: nil}), do: nil

  def render_key(%Issue{key_number: key_number} = issue) do
    case ensure_project_preloaded(issue).project do
      %Project{key_prefix: prefix} when is_binary(prefix) -> "#{prefix}-#{key_number}"
      _ -> nil
    end
  end

  defp ensure_project_preloaded(%Issue{project: %Ecto.Association.NotLoaded{}} = issue),
    do: Repo.preload(issue, :project)

  defp ensure_project_preloaded(%Issue{} = issue), do: issue

  # ── update / append_note (unchanged) ────────────────────────────────

  def update_issue(%Issue{} = issue, attrs) do
    issue
    |> Issue.changeset(attrs)
    |> Repo.update()
  end

  @doc "Appends `note` to an issue's append-only `notes` field, separated by a blank line."
  def append_note(%Issue{} = issue, note) do
    updated =
      case issue.notes do
        nil -> note
        "" -> note
        existing -> existing <> "\n\n" <> note
      end

    update_issue(issue, %{notes: updated})
  end

  # ── legacy close/reopen (unchanged; back FeatureRequests + IssueLive) ──

  @doc "Transitions an issue to closed status. Legacy — see moduledoc; use close_issue/2 for new code."
  def close_issue(%Issue{} = issue), do: update_issue(issue, %{status: "closed"})

  @doc "Transitions a closed issue back to open status. Legacy — see moduledoc; use reopen_issue/2 for new code."
  def reopen_issue(%Issue{} = issue), do: update_issue(issue, %{status: "open"})

  # ── close_issue/2 — the read-back flow's write path (§4.2/§4.3/§6.6) ──

  @doc """
  Closes an issue: derives and freezes `commits`/`attempts` server-side
  (there is deliberately no way for a caller to hand-type them — §4.2),
  sets `status` from `outcome`, stamps `closed_at`/`closed_by_session_id`,
  and stores `resolution`. `attrs`:

    * `:outcome` (required) - `"resolved"` (-> status `"closed"`) or
      `"abandoned"` (-> status `"abandoned"`)
    * `:resolution` (required) - what actually happened
    * `:session_id` (optional) - stamped as `closed_by_session_id`
    * `:superseded_by_issue_id` (optional)

  Returns `{:ok, issue}`, `{:error, changeset}`, `{:error, :invalid_outcome}`,
  or `{:error, :resolution_required}`. Enforcing "outcome/resolution
  required to actually close" here (rather than in the changeset) keeps
  `update_issue/2`/legacy `close_issue/1` free to keep setting
  `status: "closed"` directly with no resolution, same as today.
  """
  def close_issue(%Issue{} = issue, attrs) do
    with {:ok, outcome} <- fetch_outcome(attrs),
         {:ok, resolution} <- fetch_resolution(attrs) do
      update_attrs =
        %{
          status: outcome_to_status(outcome),
          resolution: resolution,
          commits: derive_commits(issue),
          attempts: derive_attempt_summary(issue),
          closed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          closed_by_session_id: attrs[:session_id]
        }
        |> maybe_put_superseded_by(attrs[:superseded_by_issue_id])

      update_issue(issue, update_attrs)
    end
  end

  defp fetch_outcome(attrs) do
    case attrs[:outcome] do
      outcome when outcome in ["resolved", "abandoned"] -> {:ok, outcome}
      _ -> {:error, :invalid_outcome}
    end
  end

  defp fetch_resolution(attrs) do
    case attrs[:resolution] do
      resolution when is_binary(resolution) and resolution != "" -> {:ok, resolution}
      _ -> {:error, :resolution_required}
    end
  end

  defp outcome_to_status("resolved"), do: "closed"
  defp outcome_to_status("abandoned"), do: "abandoned"

  defp maybe_put_superseded_by(attrs, nil), do: attrs
  defp maybe_put_superseded_by(attrs, id), do: Map.put(attrs, :superseded_by_issue_id, id)

  # ── reopen_issue/2 — preserve-then-clear (§3.5.1) ───────────────────

  @doc """
  Reopens a closed/abandoned issue per issues_spec.md §3.5.1: BEFORE
  clearing anything, auto-appends a note archiving what's about to be
  cleared (so the historical record of "what we believed when we closed
  it" is never silently lost), then clears `commits`/`attempts`/
  `resolution`/`closed_at`/`closed_by_session_id` back to `[]`/`nil` and
  sets `status: "open"`. `superseded_by_issue_id` is deliberately NOT
  cleared (§3.5.1 step 2 — reopening despite a supersession is a
  separate, deliberate call to make via `update_issue/2`).
  """
  def reopen_issue(%Issue{} = issue, session_id) do
    with {:ok, issue} <- append_note(issue, reopen_archive_note(issue, session_id)) do
      update_issue(issue, %{
        status: "open",
        commits: [],
        attempts: [],
        resolution: nil,
        closed_at: nil,
        closed_by_session_id: nil
      })
    end
  end

  defp reopen_archive_note(issue, session_id) do
    """
    [reopened #{now_iso8601()}, session #{session_id}]
    Previously closed as #{outcome_label(issue.status)} by session #{issue.closed_by_session_id || "unknown"} at #{format_timestamp(issue.closed_at)}.
    Resolution at close:
    #{issue.resolution || "(none recorded)"}
    Frozen at that close — #{length(issue.commits)} commit(s): #{format_commits(issue.commits)}
    #{length(issue.attempts)} attempt(s): #{format_attempts(issue.attempts)}
    """
    |> String.trim_trailing()
  end

  defp now_iso8601, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp outcome_label("closed"), do: "resolved"
  defp outcome_label("abandoned"), do: "abandoned"
  defp outcome_label(other), do: other

  defp format_timestamp(nil), do: "an unknown time"
  defp format_timestamp(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_timestamp(other), do: to_string(other)

  defp format_commits([]), do: "(none)"

  defp format_commits(commits) do
    Enum.map_join(commits, ", ", fn c -> "#{field(c, :short_hash)}: #{field(c, :subject)}" end)
  end

  defp format_attempts([]), do: "(none)"

  defp format_attempts(attempts) do
    Enum.map_join(attempts, ", ", fn a ->
      "#{field(a, :session_id)}: #{field(a, :status)} — #{field(a, :outcome)}"
    end)
  end

  # commits/attempts are atom-keyed maps right after derive_commits/1 /
  # derive_attempt_summary/1 build them, but string-keyed once round-tripped
  # through the jsonb column on a freshly-loaded Issue — accept either.
  defp field(map, key), do: Map.get(map, key) || Map.get(map, to_string(key))

  # ── dedup (§7) ────────────────────────────────────────────────────────

  @doc """
  Finds an open issue in `project_id` with the same `kind` whose title is
  similar to `title` — case-insensitive substring or >= 60% word overlap,
  the same heuristic `OrcaHub.MCP.Tools.FeatureRequests` used, generalized
  from title-prefix scoping to the real `kind` column (§7).
  """
  def find_similar_open_issue(project_id, kind, title) do
    project_id
    |> list_open_issues_for_project()
    |> Enum.filter(&(&1.kind == kind))
    |> Enum.find(&similar_title?(&1.title, title))
  end

  defp similar_title?(existing_title, new_title) do
    existing_norm = normalize_title(existing_title)
    new_norm = normalize_title(new_title)

    String.contains?(existing_norm, new_norm) or String.contains?(new_norm, existing_norm) or
      word_overlap_ratio(existing_norm, new_norm) >= 0.6
  end

  defp normalize_title(title), do: title |> String.downcase() |> String.trim()

  defp word_overlap_ratio(a, b) do
    words_a = title_words(a)
    words_b = title_words(b)

    if words_a == [] or words_b == [] do
      0.0
    else
      common =
        MapSet.intersection(MapSet.new(words_a), MapSet.new(words_b))
        |> MapSet.size()

      common / min(length(words_a), length(words_b))
    end
  end

  defp title_words(title) do
    title
    |> String.split(~r/\W+/, trim: true)
    |> Enum.filter(&(String.length(&1) > 2))
  end

  # ── commits/attempts: derive live, freeze at close (§4) ─────────────

  defp attempt_sessions(issue_id) do
    Repo.all(from s in Session, where: s.issue_id == ^issue_id, order_by: [asc: s.inserted_at])
  end

  @doc """
  Computes an issue's commits the same way close_issue/2 freezes them
  (issues_spec.md §4.2): the union of (a) commits in the project
  directory's history grepped for the `OrcaHub-Issue:` trailer (both the
  rendered key and the raw UUID form, since either may appear depending
  on when the commit was made) and (b) every linked attempt session's own
  `list_session_commits/2` (using each attempt's own `directory`, which
  can differ from the project's), deduped by hash and sorted by date.
  Also usable standalone as a retroactive/fallback query (§5.1) or as
  `close_issue`'s first-call "harvested evidence" preview (§6.6).
  """
  def derive_commits(%Issue{} = issue) do
    issue = ensure_project_preloaded(issue)

    trailer_commits =
      case issue.project do
        %Project{directory: directory} when is_binary(directory) ->
          [render_key(issue), issue.id]
          |> Enum.reject(&is_nil/1)
          |> Enum.flat_map(&Sessions.git_log_by_grep(directory, "OrcaHub-Issue: #{&1}"))

        _ ->
          []
      end

    attempt_commits =
      issue.id
      |> attempt_sessions()
      |> Enum.flat_map(&Sessions.list_session_commits(&1.directory, &1.id))

    (trailer_commits ++ attempt_commits)
    |> Enum.uniq_by(& &1.hash)
    |> Enum.sort_by(& &1.date)
  end

  @doc """
  Computes an issue's compact attempt summary the same way close_issue/2
  freezes it (issues_spec.md §4.3): one `%{session_id, status, outcome}`
  per linked attempt session, oldest first — deliberately NOT a
  transcript and NOT per-attempt commit detail (that's already covered by
  `derive_commits/1`). `outcome` is the first line of the session's last
  assistant message, truncated to ~150 chars, or `"(no final message)"`.
  """
  def derive_attempt_summary(%Issue{} = issue) do
    issue.id
    |> attempt_sessions()
    |> Enum.map(fn session ->
      %{
        session_id: session.id,
        status: session.status,
        outcome: one_line_outcome(session)
      }
    end)
  end

  defp one_line_outcome(session) do
    case Sessions.last_assistant_text(session.id) do
      nil ->
        "(no final message)"

      text ->
        text
        |> String.split("\n", parts: 2)
        |> hd()
        |> String.slice(0, 150)
    end
  end

  # Full detail is capped to the most recent N attempts (issues_spec.md
  # §13 risk 5) — an issue with a runaway number of linked sessions
  # shouldn't turn a live get_issue/close_issue-preview call into N git-log
  # subprocess spawns. Older attempts fall back to a bare {session_id,
  # status} pair.
  @live_attempts_full_detail_cap 20

  @doc """
  The rich, LIVE attempt projection for an open/in_progress issue
  (issues_spec.md §3.5/§6.3) — one map per linked attempt session with
  full detail (`last_assistant_text`, `progress_phase`/`progress_note`,
  that attempt's own `commits`, `started_at`/`updated_at`) for the most
  recent #{@live_attempts_full_detail_cap}, and a bare `%{session_id,
  status}` for any older than that. Nothing here is persisted — this is
  assembled fresh on every call, the read-time counterpart to
  `derive_attempt_summary/1`'s close-time freeze.
  """
  def live_attempts(%Issue{} = issue) do
    sessions = attempt_sessions(issue.id)
    total = length(sessions)

    {bare_sessions, full_sessions} =
      if total > @live_attempts_full_detail_cap do
        Enum.split(sessions, total - @live_attempts_full_detail_cap)
      else
        {[], sessions}
      end

    Enum.map(bare_sessions, &%{session_id: &1.id, status: &1.status}) ++
      Enum.map(full_sessions, &live_attempt_detail/1)
  end

  defp live_attempt_detail(session) do
    %{
      session_id: session.id,
      status: session.status,
      last_assistant_text: Sessions.last_assistant_text(session.id),
      progress_phase: session.progress_phase,
      progress_note: session.progress_note,
      commits: Sessions.list_session_commits(session.directory, session.id),
      started_at: session.inserted_at,
      updated_at: session.updated_at
    }
  end
end
