defmodule OrcaHub.Sessions.FileSurgery do
  @moduledoc """
  Qualitative distress detector for "file surgery" — a worker rebuilding a
  tracked source file from shell fragments (`cat file | head -215 >
  /tmp/x`) instead of re-reading and retrying its editor tool (ORCAHUB3-61).

  This is deliberately separate from `OrcaHub.Sessions.Churn`, which is
  VOLUMETRIC (call rate + repetition ratio) and is structurally blind to
  this pattern: the observed incident showed 3 tool calls/5min and a
  repetition ratio of 0.07-0.27 — every volumetric gate stayed false while
  the worker did the single most dangerous thing it did all session.

  A same-day second incident (the qwen worker that produced this module's
  own broken first draft) used `sed -i` and a `File.write!` script with NO
  redirection at all — a redirection-only matcher misses that entirely.
  `detect/1` checks four families, tried highest-precision first:

    a. `:write_to_tracked`   — shell WRITES to a tracked path: `... >
       lib/foo.ex`, `... >> lib/foo.ex`, `tee lib/foo.ex`, `cp x
       lib/foo.ex`, `mv x lib/foo.ex`.
    b. `:in_place_edit`      — in-place mutation: `sed -i`, `perl -pi`/`-i`.
    c. `:programmatic_write` — a write primitive (`File.write!`,
       `open(..., "w")`, `Path(...).write_text`) whose OWN ARGUMENT is a
       tracked path.
    d. `:slice_and_redirect` — the original ORCAHUB3-61 case: redirection
       whose INPUT is a text-slicing read (`cat`/`head`/`tail`/`sed -n`/
       `awk`) of a tracked path.

  Direction matters for family (a): `cp lib/foo.ex lib/foo.ex.bak` is a
  benign backup (destination isn't a tracked-source extension) and must
  NOT fire, but `cp lib/foo.ex.bak lib/foo.ex` writes into the tracked
  file and MUST — restoring from a backup is still an uninspected write.

  Family ordering and severity are MEASURED, not guessed — see
  `churn_signal_mining.md` (296 labelled intervention events / 92 clean
  controls from `orca_hub_prod`): `:programmatic_write` P=1.00 R=0.02,
  `:slice_and_redirect` P=0.92 R=0.08, `:write_to_tracked` P=0.83 R=0.10,
  `:in_place_edit` P=0.73 R=0.06; combined A∨B∨C∨D is P=0.81 R=0.16 (vs
  D alone P=0.92 R=0.08) — roughly 2x the recall for an ~11-point
  precision cost, the right trade for an ADVISORY alert an orchestrator
  judges. Within claude sessions specifically, family D is nearly INERT
  (2 true positives) while A∨B∨C finds 16 — family A is load-bearing for
  that backend, not the cat/head sub-pattern this issue was written
  around.

  `detect/1`'s evidence map reports WHICH pattern fired (`kind`, a family
  atom) and two pieces of context for the policy layer to weigh
  (`verified_in_command`, `same_path_matches`) — see the fields' individual
  docs below. Deciding whether any of it is worth an alert is
  `OrcaHub.Sessions.SurgeryAlertPolicy`'s job, not this module's.

  Computed from the messages table's assistant `tool_use` blocks (mirrors
  `OrcaHub.Sessions.ChurnDetail`'s extraction shape exactly — see its
  moduledoc). `detect/1` is pure and never raises.

  ## What seven weeks of production said (ORCAHUB3-66)

  `churn_alert_precision.md` measured every alert this detector has ever
  delivered — 229 file-surgery alerts, 2026-08-23 → 2026-09-19 — against a
  hand-labelled sample. Three findings are load-bearing for the code below.

  **Defect A.6(1), fixed here: family (c) used to name a path it merely
  READ.** It split the whole command on whitespace/quotes and took the first
  token that looked tracked, so a `python3 - <<'PY'` script that reads
  `lib/foo.ex` and writes `/tmp/out.txt` was reported as "worker rebuilding
  lib/foo.ex". `:programmatic_write` is 56.8% of the corpus (130/229), so
  this was corrupting the largest bucket. The reported path is now the
  argument of the write primitive itself, and an INDETERMINATE write target
  returns `nil` rather than a guess — naming the wrong file is what destroys
  an advisory's credibility, and a missed detection is far cheaper. Replayed
  over the 229 delivered commands, the fix drops **17 (7.4%)**: 11 whose
  real write target is not a tracked source path at all (§A.6's own sample
  #6 wrote `/tmp/tts-arb-check/blocks.txt` while the alert named
  `/home/zach/projects/tts/README.md`) and 6 whose target is genuinely
  indeterminate (`open(path, "w")` inside a loop). A further 3 keep firing
  but now name the file actually written.

  **Defect A.6(2), fixed here: `>` inside a quoted string was read as a
  redirect.** Sample #27's command is a pure READ whose only `>` is the
  literal `<redacted>` in `sed 's/PASSWORD=.*/PASSWORD=<redacted>/'`.
  Quoted segments and heredoc BODIES are now blanked before any redirect
  operator is looked for. Measured: **3 of 229 (1.3%)** — #27 itself, plus
  two of the twelve §E deploy-runner alerts, whose only `>` came from
  `echo "=== diff run-a.sh -> run-b.sh ==="`. Two MORE alerts keep firing
  with a corrected target: a quoted `>` (a `=>` arrow function inside a
  heredoc) had been shadowing the command's real redirect.

  Replaying both fixes over the corpus: 20/229 (8.7%) stop firing, 5 fire
  on a corrected path or family, and all **3 hand-labelled true positives
  survive** — the only alert from the labelled sample that disappears is
  #27, the parse artefact above.

  **There is no `paired_with_failed_edit` field any more.** It was a
  confidence modifier — "a failed `Edit`/`Write`/`MultiEdit` on this path
  preceded the shell write" — and it was never once true across all 229
  delivered alerts, every one of which was therefore labelled "unpaired
  (lower confidence)" against a high-confidence branch that could not
  occur. The concept graduated into `OrcaHub.Sessions.EditFailure`, which
  detects "this worker cannot land an edit" as a signal in its own right:
  failed editor calls number 0 in 223 of the 229 alert windows, so the two
  populations are disjoint and were never a confidence modifier on each
  other in the first place.

  **What the denominator is.** Every count in this moduledoc is measured
  against alerts that were actually DELIVERED. It is not a sample of all
  DETECTIONS: nothing persisted a detection that did not become an alert
  (`ChurnSampler.run_sweep/1` calls `Churn.assess/3`, so `churn_samples`
  never carried file surgery at all). Read each figure as "of the alerts
  that WERE delivered historically, N would not have been" — never as "N%
  of detections". The comparison also cannot be repeated the same way on
  future data until that observability gap is closed, since an alert
  suppressed by `SurgeryAlertPolicy` will not appear in the delivered
  corpus either.

  Suppression POLICY is deliberately not here: `detect/1` reports evidence,
  `OrcaHub.Sessions.SurgeryAlertPolicy` decides what to do with it.
  """

  import Ecto.Query

  require Logger

  alias OrcaHub.Repo
  alias OrcaHub.Sessions.Message

  @default_window_minutes 30
  @sweep_window_minutes 10

  @tracked_extensions ~w(.ex .exs .eex .heex .leex .js .jsx .ts .tsx .css .scss .json .yaml .yml .md .sh .sql .html .erl .hrl .py .toml)
  @excluded_substrings ~w(/tmp/ /var/ _build/ deps/ node_modules/ priv/static/ .git/ log/ logs/ .elixir_ls/ cover/)

  @sanctioned_git_regex ~r/\bgit\s+(show|cat-file|diff|archive)\b/
  @benign_formatter_regex ~r/\bmix\s+format\b|\bprettier\b.*--write|\beslint\b.*--fix/
  @in_place_regex ~r/\bsed\s+(-\S*i\S*|--in-place\S*)|\bperl\s+-\S*i\S*/

  # Family (c) WRITE TARGETS — see the moduledoc's defect A.6(1) note. Each
  # regex captures the write primitive's OWN first argument: a double-quoted
  # literal, a single-quoted literal, or a bare identifier (resolved against
  # @binding_regex below). There is deliberately no looser "command contains a
  # write primitive AND a tracked-looking token" fallback: that WAS the defect.
  @file_write_regex ~r/File\.write!?\(\s*(?:"([^"]*)"|'([^']*)')/
  @open_write_regex ~r/open\(\s*(?:"([^"]*)"|'([^']*)')\s*,[^)]*["'][^"']*w[^"']*["']/
  # `Path("x")`, `pathlib.Path("x")` — the qualifier is optional.
  @path_write_text_regex ~r/(?:[A-Za-z_][\w.]*\.)?Path\(\s*(?:"([^"]*)"|'([^']*)')\s*\)\s*\.write_text\(/
  @literal_write_regexes [@file_write_regex, @open_write_regex, @path_write_text_regex]

  # Same three primitives, written against a BARE IDENTIFIER instead of a
  # literal — resolved through @binding_regex below.
  @file_write_var_regex ~r/File\.write!?\(\s*([A-Za-z_]\w*)\s*,/
  @open_write_var_regex ~r/open\(\s*([A-Za-z_]\w*)\s*,[^)]*["'][^"']*w[^"']*["']/
  @var_write_text_regex ~r/(?:^|[^\w.])([A-Za-z_]\w*)\s*\.write_text\(/
  @var_write_regexes [@file_write_var_regex, @open_write_var_regex, @var_write_text_regex]

  # `p = 'lib/foo.ex'` / `p = Path("lib/foo.ex")` — the overwhelmingly common
  # shape in the corpus is `p='x.py'` … `open(p,'w').write(s)`, so a write
  # target given as a bare identifier is resolved from the literal binding in
  # force AT that write (see `binding_before/3`). A target with no literal
  # binding before it stays indeterminate and fires nothing.
  @binding_regex ~r/(?:^|[^\w.])([A-Za-z_]\w*)\s*=\s*(?:(?:[A-Za-z_][\w.]*\.)?Path\(\s*)?(?:"([^"]*)"|'([^']*)')/

  # Heredoc marker: `<<EOF`, `<<'PY'`, `<<-"SQL"`. Used to find the BODY,
  # which is data rather than shell syntax — see defect A.6(2).
  @heredoc_marker_regex ~r/<<-?\s*(?:"([A-Za-z_]\w*)"|'([A-Za-z_]\w*)'|([A-Za-z_]\w*))/

  # D2b, ported from the ORCAHUB3-66 analysis
  # (/home/zach/orca-hub-churn-analysis/discriminators.exs) so the shipped
  # `verified_in_command` matches the 27.5% suppression figure measured there.
  # The read-back half deliberately does NOT require the path to be named —
  # that is the predicate that was measured, and `&& head -20` after a write
  # is nearly always about the thing just written.
  @read_back_regex ~r/(&&|;)\s*(diff|grep|cat|head|tail|wc|ls|md5sum|sha256sum)\b/
  @exec_verify_prefix "(&&|;|\\|)\\s*(sudo\\s+)?(timeout\\s+\\d+\\s+)?" <>
                        "(mix run|mix test|elixir|node|node --check|python3?|uv run|pytest|" <>
                        "bash -n|sh -n|ruff|\\.\\/)\\S*\\s*[^\\n]*"

  @doc """
  Fetches `session_id`'s messages from the last `window_minutes` (default
  #{@default_window_minutes}) and runs `detect/1` over them.

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
        "FileSurgery.fetch/2 failed for session #{inspect(session_id)}: #{Exception.message(e)}"
      )

      nil
  end

  @doc """
  Batched fetch for many sessions in ONE query — the hot path for a
  per-watched-session sweep (default window #{@sweep_window_minutes}
  minutes, shorter than `fetch/2`'s, since this runs every 120s and must
  stay cheap; ~5x redundancy at that cadence).

  Returns `%{session_id => evidence_or_nil}`. Every id in `session_ids` is
  guaranteed to be a key of the result — a session with no messages (or no
  match) in the window maps to `nil`, it is never simply absent, and that
  guarantee holds on the FAILURE PATH too (see below): a caller reasonably
  reads a missing key as "not computed yet" and a `nil` value as "no
  evidence", so returning `%{}` under failure would silently change that
  meaning rather than obviously breaking.

  An invalid `session_id` (fails to parse as a UUID) is filtered out
  BEFORE the batch query rather than left to raise inside it — since this
  one query covers the whole watched set at once, a single bad id must
  never poison every OTHER session's result. `detect/1` is already
  per-session safe (`safely/1` wraps it, run once per group), so the
  query is the only all-or-nothing step in this function; a genuine DB
  failure past the filter is still caught by the outer rescue as a
  backstop, mapping every requested id to `nil`.
  """
  def fetch_many(session_ids, opts \\ []) when is_list(session_ids) do
    window_minutes = Keyword.get(opts, :window_minutes, @sweep_window_minutes)
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-window_minutes * 60, :second)

    {valid_ids, invalid_ids} = Enum.split_with(session_ids, &valid_uuid?/1)

    if invalid_ids != [] do
      Logger.warning(
        "FileSurgery.fetch_many/2 dropped invalid session ids: #{inspect(invalid_ids)}"
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
        "FileSurgery.fetch_many/2 failed for #{length(session_ids)} session(s): #{Exception.message(e)}"
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
  `ChurnDetail.compute/1`'s seam.

  Returns the MOST RECENT match in the window as an evidence map:

      %{path: "lib/orca_hub/pi_config_sync.ex",
        command: "<full Bash command string>",
        kind: :write_to_tracked | :in_place_edit | :programmatic_write | :slice_and_redirect,
        verified_in_command: boolean,
        same_path_matches: pos_integer}

  or `nil` if no file-surgery pattern is found. Never raises. `kind` names
  WHICH match family fired — see the moduledoc for the four families,
  their precedence order, and their measured precision/recall.

  `git show`/`cat-file`/`diff`/`archive` (even when the output target is a
  tracked path — that's the SANCTIONED recovery procedure) and formatter
  commands (`mix format`, `prettier --write`, `eslint --fix`) are excluded
  before any family is checked.

  `verified_in_command` is the measured D2b signal: `true` when the flagged
  command ITSELF, after the write, either reads the written path back
  (`diff`/`grep`/`cat`/`head`/`tail`/`wc`/`ls`/`md5sum`) or EXECUTES what it
  wrote (`mix run`, `mix test`, `node`, `python3 <file>`, `uv run`,
  `pytest`, `bash -n`, `./<file>`). A worker that exercises its own output
  is not in a blind repair loop — the loop does neither. The "executes"
  half is load-bearing: read-back alone (D2a) misses the live specimen in
  §C.4 of `churn_alert_precision.md`, which is the measured argument for
  the wider form (27.5% of the corpus vs 22.7%).

  `same_path_matches` counts how many surgery matches in the window landed
  on the SAME path, this one included (so it is always >= 1). It is
  **INFORMATIONAL ONLY and must never gate anything** — see its own note at
  the call site.
  """
  def detect(messages) when is_list(messages) do
    safely(fn ->
      matches =
        messages
        |> Enum.flat_map(&tool_use_blocks/1)
        |> Enum.flat_map(fn block ->
          with cmd when is_binary(cmd) <- bash_command(block),
               {path, kind} <- match_surgery_pattern(cmd) do
            [{path, kind, cmd}]
          else
            _ -> []
          end
        end)

      case List.last(matches) do
        nil ->
          nil

        {path, kind, cmd} ->
          %{
            path: path,
            command: cmd,
            kind: kind,
            verified_in_command: verified_in_command?(cmd, path),
            # INFORMATIONAL ONLY. This number must NEVER gate an alert.
            # ORCAHUB3-66 §D measured the obvious discriminator built on it
            # ("one match = style, >=2 = repair loop", D4): it suppresses
            # 81.2% of the corpus — and destroys 3 of 3 hand-labelled true
            # positives, every one of which fired on a path matched exactly
            # once. §C.4 refutes it from the other side in the wild: three
            # writes to one scratch path, unambiguously benign, because
            # iterating on a scratch script is the most normal thing anyone
            # does with a scratch script. It looks superb in aggregate and is
            # wrong in kind. Carried for the alert message and future mining.
            same_path_matches: Enum.count(matches, fn {p, _, _} -> p == path end)
          }
      end
    end)
  end

  def detect(_), do: nil

  defp safely(fun) do
    fun.()
  rescue
    _ -> nil
  end

  # -------------------------------------------------------------------
  # Matcher
  # -------------------------------------------------------------------

  defp bash_command(%{"type" => "tool_use", "name" => "Bash", "input" => %{"command" => cmd}})
       when is_binary(cmd),
       do: cmd

  defp bash_command(_), do: nil

  defp match_surgery_pattern(cmd) do
    if Regex.match?(@sanctioned_git_regex, cmd) or Regex.match?(@benign_formatter_regex, cmd) do
      nil
    else
      match_families(cmd, cmd |> shell_operators_only() |> strip_error_redirects())
    end
  end

  # `operators` is the command with every quoted segment and heredoc body
  # blanked and the error redirects stripped — the only view in which a `>`
  # reliably means redirection. Families (b) and (c) read the raw command,
  # since the code they match on LIVES inside those quotes and heredocs.
  defp match_families(cmd, operators) do
    cond do
      path = match_family_a(cmd, operators) ->
        {path, :write_to_tracked}

      path = match_family_b(cmd) ->
        {path, :in_place_edit}

      path = match_family_c(cmd) ->
        {path, :programmatic_write}

      path = match_family_d(operators) ->
        {path, :slice_and_redirect}

      true ->
        nil
    end
  end

  # (a) WRITE TO a tracked path from the shell: real redirection whose
  # OUTPUT target is tracked, or cp/mv/tee writing into one. Direction
  # matters — only the destination is checked, so `cp x.ex x.ex.bak` (dest
  # not a tracked-source extension) is benign but `cp x.ex.bak x.ex` fires.
  defp match_family_a(cmd, operators) do
    redirect_target = real_output_redirect?(operators) && extract_redirect_target(operators)

    cond do
      is_binary(redirect_target) and tracked_source_path?(redirect_target) -> redirect_target
      true -> match_cp_mv_tee_target(cmd)
    end
  end

  # `cp`/`mv` must be the whole command; `tee` is checked per pipeline
  # stage too, since its usual form is `cmd | tee file`.
  defp match_cp_mv_tee_target(cmd) do
    cmd
    |> String.split("|")
    |> Enum.map(&String.trim/1)
    |> Enum.find_value(&match_cp_mv_tee_stage/1)
  end

  defp match_cp_mv_tee_stage(stage) do
    case String.split(stage) do
      [tool | rest] when tool in ["cp", "mv"] ->
        case Enum.reject(rest, &String.starts_with?(&1, "-")) do
          [_src, dst] -> if tracked_source_path?(dst), do: dst
          _ -> nil
        end

      ["tee" | rest] ->
        case Enum.reject(rest, &String.starts_with?(&1, "-")) do
          [dst] -> if tracked_source_path?(dst), do: dst
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # (b) IN-PLACE mutation: `sed -i`, `perl -pi`/`-i`. The target path is
  # always the last whitespace token, even when the script body itself
  # contains unescaped spaces (they're never the LAST token).
  defp match_family_b(cmd) do
    if Regex.match?(@in_place_regex, cmd) do
      path = cmd |> String.split() |> List.last()
      if is_binary(path) and tracked_source_path?(path), do: path
    end
  end

  # (c) PROGRAMMATIC rewrite: a write primitive whose OWN ARGUMENT is a
  # tracked path — `File.write!("lib/foo.ex", …)`, `open(p, "w")` with
  # `p = 'lib/foo.ex'`, `Path("lib/foo.ex").write_text(…)`.
  #
  # The path reported here USED to be "the first token anywhere in the
  # command that looks tracked", which is defect A.6(1): a `python3 - <<'PY'`
  # script that reads `lib/foo.ex` and writes `/tmp/out.txt` was reported as
  # rebuilding `lib/foo.ex`. If the write target cannot be determined
  # confidently we return nil and do not fire — a missed detection costs
  # nothing next to an alert that names the wrong file.
  defp match_family_c(cmd) do
    cmd
    |> write_target_candidates()
    |> Enum.find(&tracked_source_path?/1)
  end

  defp write_target_candidates(cmd) do
    literals = Enum.flat_map(@literal_write_regexes, &scan_first_captures(&1, cmd))
    bindings = literal_bindings(cmd)

    from_vars =
      @var_write_regexes
      |> Enum.flat_map(&scan_capture_positions(&1, cmd))
      |> Enum.map(fn {offset, var} -> binding_before(bindings, var, offset) end)

    Enum.reject(literals ++ from_vars, &is_nil/1)
  end

  defp scan_first_captures(regex, cmd) do
    regex
    |> Regex.scan(cmd)
    |> Enum.map(fn captures ->
      captures |> Enum.drop(1) |> Enum.find(&(&1 not in [nil, ""]))
    end)
    |> Enum.reject(&is_nil/1)
  end

  # `{byte offset of the captured identifier, identifier}` — the offset is
  # what makes `binding_before/3` sequential rather than a guess.
  defp scan_capture_positions(regex, cmd) do
    regex
    |> Regex.scan(cmd, return: :index)
    |> Enum.flat_map(fn captures ->
      case Enum.drop(captures, 1) do
        [{offset, _} = index | _] -> [{offset, slice_at(cmd, index)}]
        _ -> []
      end
    end)
    |> Enum.reject(fn {_, var} -> var in [nil, ""] end)
  end

  # `%{var => [{offset, literal}]}` for every `p = "lit"` / `p = Path('lit')`
  # in the command.
  defp literal_bindings(cmd) do
    @binding_regex
    |> Regex.scan(cmd, return: :index)
    |> Enum.reduce(%{}, fn captures, acc ->
      with [{offset, _} = var_index | literal_indexes] <- Enum.drop(captures, 1),
           var when var not in [nil, ""] <- slice_at(cmd, var_index),
           literal when literal not in [nil, ""] <-
             literal_indexes |> Enum.map(&slice_at(cmd, &1)) |> Enum.find(&(&1 not in [nil, ""])) do
        Map.update(acc, var, [{offset, literal}], &[{offset, literal} | &1])
      else
        _ -> acc
      end
    end)
  end

  # The binding in force AT the write — the LAST one textually before it.
  # Straight-line patch scripts rebind the same name per file
  # (`p='a.ex'; …; open(p,'w')…; p='b.ex'; …; open(p,'w')…`), so "the
  # variable has two bindings, give up" would throw away real detections,
  # while "take any binding" is the guess this whole fix exists to avoid. A
  # write through a variable with no literal binding before it (an argv
  # value, an `os.path.join(...)`) stays indeterminate and yields nil.
  defp binding_before(bindings, var, offset) do
    bindings
    |> Map.get(var, [])
    |> Enum.filter(fn {o, _} -> o < offset end)
    |> Enum.sort_by(fn {o, _} -> o end)
    |> List.last()
    |> case do
      {_offset, literal} -> literal
      nil -> nil
    end
  end

  defp slice_at(_cmd, {-1, _length}), do: nil
  defp slice_at(cmd, {offset, length}), do: binary_part(cmd, offset, length)
  defp slice_at(_cmd, _index), do: nil

  # (d) SLICE-AND-REDIRECT — the original ORCAHUB3-61 case: redirection
  # whose INPUT is a text-slicing read of a tracked path.
  defp match_family_d(cmd) do
    if real_output_redirect?(cmd) do
      case split_at_real_redirect(cmd) do
        nil ->
          nil

        left ->
          case extract_slicing_path(left) do
            nil -> nil
            path -> if tracked_source_path?(path), do: path
          end
      end
    end
  end

  # A bare `2>&1` / `2>` redirect alone must not be the trigger. Strip
  # those specific error-redirect tokens first, then check what's left.
  defp strip_error_redirects(cmd) do
    cmd
    |> String.replace(~r/2>&1/, " ")
    |> String.replace(~r/2>>?\s*\S+/, " ")
  end

  # ------------------------------------------------------------------
  # Shell-operator view (defect A.6(2))
  # ------------------------------------------------------------------
  # A `>` only means redirection when the SHELL sees it as an operator. A
  # `>` inside a quoted string, or inside a heredoc BODY, is data. The
  # canonical production instance: the only `>` in
  # `… | sed 's/PASSWORD=.*/PASSWORD=<redacted>/'` is the literal
  # `<redacted>`, and the command is a pure READ. (`churn_alert_precision.md`
  # said BOTH `slice_and_redirect` alerts were this bug, in §A.3 AND in
  # §A.6(2) itself. Replaying the corpus says one of the two — sample #27,
  # above — is; the other is a genuine `sed -n '526,645p' file.js > /tmp/x`
  # that still fires after this fix. Corrected in the doc at 56e2807.)
  #
  # The blanking is LENGTH-PRESERVING — every masked byte becomes a space,
  # while quote delimiters and newlines stay where they are — so an offset in
  # this view is the same offset in the original command and the redirect
  # TARGET can be read straight back out of it. (Only a QUOTED target would
  # come back blanked, and a quoted target never matched
  # `tracked_source_path?/1` in the first place: the closing quote is part of
  # the token.) Only `strip_error_redirects/1`, whose behaviour is unchanged,
  # shifts anything, exactly as it always did.
  defp shell_operators_only(cmd) do
    cmd |> blank_heredoc_bodies() |> blank_quoted_segments()
  end

  defp blank_heredoc_bodies(cmd) do
    cmd
    |> String.split("\n")
    |> Enum.map_reduce([], fn
      line, [] ->
        {line, heredoc_markers(line)}

      line, [terminator | rest] = pending ->
        if String.trim(line) == terminator,
          do: {line, rest},
          else: {blank(line), pending}
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  defp heredoc_markers(line) do
    @heredoc_marker_regex
    |> Regex.scan(line)
    |> Enum.map(fn captures ->
      captures |> Enum.drop(1) |> Enum.find(&(&1 not in [nil, ""]))
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp blank(str), do: String.duplicate(" ", byte_size(str))

  # Byte-wise, so offsets survive: quote characters are ASCII and every byte
  # of a masked multi-byte grapheme is masked together.
  defp blank_quoted_segments(str), do: blank_quoted(str, nil, [])

  defp blank_quoted(<<>>, _quote, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp blank_quoted(<<?\\, c, rest::binary>>, nil, acc),
    do: blank_quoted(rest, nil, [c, ?\\ | acc])

  defp blank_quoted(<<q, rest::binary>>, nil, acc) when q in [?', ?"],
    do: blank_quoted(rest, q, [q | acc])

  defp blank_quoted(<<c, rest::binary>>, nil, acc), do: blank_quoted(rest, nil, [c | acc])

  defp blank_quoted(<<q, rest::binary>>, q, acc), do: blank_quoted(rest, nil, [q | acc])

  defp blank_quoted(<<?\\, _c, rest::binary>>, ?", acc),
    do: blank_quoted(rest, ?", [?\s, ?\s | acc])

  defp blank_quoted(<<?\n, rest::binary>>, q, acc), do: blank_quoted(rest, q, [?\n | acc])

  defp blank_quoted(<<_c, rest::binary>>, q, acc), do: blank_quoted(rest, q, [?\s | acc])

  defp real_output_redirect?(operators), do: String.contains?(operators, ">")

  defp split_at_real_redirect(operators) do
    case String.split(operators, ~r/>{1,2}/, parts: 2) do
      [left, _right] -> String.trim(left)
      _ -> nil
    end
  end

  # First whitespace-delimited token right after the real redirect
  # operator — stops before a trailing heredoc marker (`<<'EOF'`) since
  # `<` is excluded from the token itself.
  defp extract_redirect_target(operators) do
    case Regex.run(~r/>{1,2}\s*([^\s<>]+)/, operators) do
      [_, target] -> target
      _ -> nil
    end
  end

  # `left` is everything before the real redirect, possibly a pipeline
  # (`cat file | head -N`). Exactly one pipeline stage should resolve to a
  # path — more or fewer is ambiguous, and an ambiguous extraction returns
  # nil rather than risk naming the wrong file.
  defp extract_slicing_path(left) do
    candidates =
      left
      |> String.split("|")
      |> Enum.map(&String.trim/1)
      |> Enum.map(&extract_from_stage/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    case candidates do
      [path] -> path
      _ -> nil
    end
  end

  defp extract_from_stage(stage) do
    case String.split(stage) do
      ["cat" | rest] -> extract_cat_path(rest)
      ["head" | rest] -> extract_head_tail_path(rest)
      ["tail" | rest] -> extract_head_tail_path(rest)
      ["sed", "-n" | rest] -> extract_script_then_path(rest)
      ["awk" | rest] -> extract_script_then_path(rest)
      _ -> nil
    end
  end

  defp extract_cat_path(rest) do
    case Enum.reject(rest, &String.starts_with?(&1, "-")) do
      [path] -> path
      _ -> nil
    end
  end

  # head/tail: `-n`/`-c` consume the following token as their value
  # (`-n 100`, `-n +216`); any other `-...` token is a flag on its own.
  defp extract_head_tail_path(rest) do
    case drop_flags_and_values(rest) do
      [path] -> path
      _ -> nil
    end
  end

  defp drop_flags_and_values(tokens) do
    {result, _skip_next} =
      Enum.reduce(tokens, {[], false}, fn tok, {acc, skip_next} ->
        cond do
          skip_next -> {acc, false}
          tok in ["-n", "-c"] -> {acc, true}
          String.starts_with?(tok, "-") -> {acc, false}
          true -> {[tok | acc], false}
        end
      end)

    Enum.reverse(result)
  end

  # sed -n / awk: positional form is `<script> [file]` — a script with no
  # trailing file token means stdin input, not a tracked-file read.
  defp extract_script_then_path(rest) do
    case Enum.reject(rest, &String.starts_with?(&1, "-")) do
      tokens when length(tokens) >= 2 -> List.last(tokens)
      _ -> nil
    end
  end

  # The word "tracked" in this function's name is ASPIRATIONAL. The check is
  # purely EXTENSION-based and never consults git: it asks "does this look
  # like source?", not "is this file in a repository?". That is why a deploy
  # worker's scratch `.sh` in /home/zach/orca-hub-deploy-logs — a directory
  # outside any git repo at all — matched family (a) twelve times in
  # production (`churn_alert_precision.md` §E), and why `probe1.exs` in an
  # analysis scratch directory matched it again (§C.4).
  #
  # Do NOT "fix" this by requiring git tracking: measured as discriminator
  # D1, that rule suppresses 44.1% of the corpus and destroys 2 of the 3
  # hand-labelled true positives, including the one case ORCAHUB3-66 must
  # keep — the wedged poll-loop worker was writing to a scratch harness
  # under `tmp/`, outside git, exactly like the deploy runner was.
  defp tracked_source_path?(path) when is_binary(path) do
    Enum.any?(@tracked_extensions, &String.ends_with?(path, &1)) and
      not Enum.any?(@excluded_substrings, &String.contains?(path, &1)) and
      not String.ends_with?(path, ".log")
  end

  defp tracked_source_path?(_), do: false

  # -------------------------------------------------------------------
  # Same-command verification (D2b)
  # -------------------------------------------------------------------

  defp verified_in_command?(cmd, path) do
    Regex.match?(@read_back_regex, cmd) or executes_written_file?(cmd, path)
  end

  defp executes_written_file?(cmd, path) when is_binary(path) do
    case Regex.compile(@exec_verify_prefix <> Regex.escape(Path.basename(path))) do
      {:ok, regex} -> Regex.match?(regex, cmd)
      {:error, _} -> false
    end
  end

  defp executes_written_file?(_cmd, _path), do: false

  # -------------------------------------------------------------------
  # Shared message parsing (mirrors ChurnDetail)
  # -------------------------------------------------------------------

  defp tool_use_blocks(%{data: data}) do
    data
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_use"))
  end

  defp tool_use_blocks(_), do: []
end
