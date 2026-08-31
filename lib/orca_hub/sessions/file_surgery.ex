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
    c. `:programmatic_write` — a command containing both a tracked path and
       a write primitive (`File.write!`, `open(..., "w")`, ...).
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
  around. `paired_with_failed_edit` is the independent, and stronger,
  confidence signal (P=0.92 paired vs P=0.72 unpaired for the same
  fragment-read pattern) — a paired `:in_place_edit` is more trustworthy
  than an unpaired one of any family.

  `detect/1`'s evidence map splits WHICH pattern fired (`kind`, a family
  atom) from HOW MUCH to trust it (`paired_with_failed_edit`, a boolean
  confidence modifier) — see the two fields' individual docs below.

  Computed from the messages table's assistant `tool_use` blocks (mirrors
  `OrcaHub.Sessions.ChurnDetail`'s extraction shape exactly — see its
  moduledoc). `detect/1` is pure and never raises.
  """

  import Ecto.Query

  alias OrcaHub.Repo
  alias OrcaHub.Sessions.Message

  @default_window_minutes 30
  @sweep_window_minutes 10
  @pairing_lookback 10

  @edit_tool_names ~w(Edit Write MultiEdit)

  @tracked_extensions ~w(.ex .exs .eex .heex .leex .js .jsx .ts .tsx .css .scss .json .yaml .yml .md .sh .sql .html .erl .hrl .py .toml)
  @excluded_substrings ~w(/tmp/ /var/ _build/ deps/ node_modules/ priv/static/ .git/ log/ logs/ .elixir_ls/ cover/)

  @sanctioned_git_regex ~r/\bgit\s+(show|cat-file|diff|archive)\b/
  @benign_formatter_regex ~r/\bmix\s+format\b|\bprettier\b.*--write|\beslint\b.*--fix/
  @in_place_regex ~r/\bsed\s+(-\S*i\S*|--in-place\S*)|\bperl\s+-\S*i\S*/
  @write_primitive_regex ~r/File\.write!?\(|open\([^)]*["']w["']/

  @doc """
  Fetches `session_id`'s messages from the last `window_minutes` (default
  #{@default_window_minutes}) and runs `detect/1` over them.
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
  end

  @doc """
  Batched fetch for many sessions in ONE query — the hot path for a
  per-watched-session sweep (default window #{@sweep_window_minutes}
  minutes, shorter than `fetch/2`'s, since this runs every 120s and must
  stay cheap; ~5x redundancy at that cadence).

  Returns `%{session_id => evidence_or_nil}`. Every id in `session_ids` is
  guaranteed to be a key of the result — a session with no messages (or no
  match) in the window maps to `nil`, it is never simply absent.
  """
  def fetch_many(session_ids, opts \\ []) when is_list(session_ids) do
    window_minutes = Keyword.get(opts, :window_minutes, @sweep_window_minutes)
    cutoff = NaiveDateTime.utc_now() |> NaiveDateTime.add(-window_minutes * 60, :second)

    messages =
      from(m in Message,
        where: m.session_id in ^session_ids and m.inserted_at >= ^cutoff,
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
  end

  @doc """
  Pure detection over an already-fetched, oldest-first list of message
  structs/maps (each needs only a `data` field/key) — mirrors
  `ChurnDetail.compute/1`'s seam.

  Returns the MOST RECENT match in the window as an evidence map:

      %{path: "lib/orca_hub/pi_config_sync.ex",
        command: "<full Bash command string>",
        kind: :write_to_tracked | :in_place_edit | :programmatic_write | :slice_and_redirect,
        paired_with_failed_edit: boolean}

  or `nil` if no file-surgery pattern is found. Never raises. `kind` names
  WHICH match family fired — see the moduledoc for the four families,
  their precedence order, and their measured precision/recall.

  `git show`/`cat-file`/`diff`/`archive` (even when the output target is a
  tracked path — that's the SANCTIONED recovery procedure) and formatter
  commands (`mix format`, `prettier --write`, `eslint --fix`) are excluded
  before any family is checked.

  `paired_with_failed_edit` is a confidence modifier, orthogonal to
  `kind`: `true` when a failed Edit/Write/MultiEdit on the SAME path
  appears in the preceding #{@pairing_lookback} tool calls, else `false`.
  """
  def detect(messages) when is_list(messages) do
    safely(fn ->
      tool_use_events = Enum.flat_map(messages, &tool_use_blocks/1)
      result_errors = build_result_index(messages)

      tool_use_events
      |> Enum.with_index()
      |> Enum.reduce(nil, fn {block, idx}, most_recent ->
        case bash_command(block) do
          nil ->
            most_recent

          cmd ->
            case match_surgery_pattern(cmd) do
              nil ->
                most_recent

              {path, kind} ->
                %{
                  path: path,
                  command: cmd,
                  kind: kind,
                  paired_with_failed_edit:
                    paired_with_failed_edit?(tool_use_events, idx, path, result_errors)
                }
            end
        end
      end)
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
    cond do
      Regex.match?(@sanctioned_git_regex, cmd) ->
        nil

      Regex.match?(@benign_formatter_regex, cmd) ->
        nil

      path = match_family_a(cmd) ->
        {path, :write_to_tracked}

      path = match_family_b(cmd) ->
        {path, :in_place_edit}

      path = match_family_c(cmd) ->
        {path, :programmatic_write}

      path = match_family_d(cmd) ->
        {path, :slice_and_redirect}

      true ->
        nil
    end
  end

  # (a) WRITE TO a tracked path from the shell: real redirection whose
  # OUTPUT target is tracked, or cp/mv/tee writing into one. Direction
  # matters — only the destination is checked, so `cp x.ex x.ex.bak` (dest
  # not a tracked-source extension) is benign but `cp x.ex.bak x.ex` fires.
  defp match_family_a(cmd) do
    redirect_target = real_output_redirect?(cmd) && extract_redirect_target(cmd)

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

  # (c) PROGRAMMATIC rewrite: a command containing both a tracked path and
  # a write primitive (`File.write!`, `open(..., "w")`, ...).
  defp match_family_c(cmd) do
    if Regex.match?(@write_primitive_regex, cmd) do
      cmd
      |> String.split(~r/[\s"'(),]+/, trim: true)
      |> Enum.find(&tracked_source_path?/1)
    end
  end

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

  defp real_output_redirect?(cmd), do: String.contains?(strip_error_redirects(cmd), ">")

  defp split_at_real_redirect(cmd) do
    case String.split(strip_error_redirects(cmd), ~r/>{1,2}/, parts: 2) do
      [left, _right] -> String.trim(left)
      _ -> nil
    end
  end

  # First whitespace-delimited token right after the real redirect
  # operator — stops before a trailing heredoc marker (`<<'EOF'`) since
  # `<` is excluded from the token itself.
  defp extract_redirect_target(cmd) do
    case Regex.run(~r/>{1,2}\s*([^\s<>]+)/, strip_error_redirects(cmd)) do
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

  defp tracked_source_path?(path) when is_binary(path) do
    Enum.any?(@tracked_extensions, &String.ends_with?(path, &1)) and
      not Enum.any?(@excluded_substrings, &String.contains?(path, &1)) and
      not String.ends_with?(path, ".log")
  end

  defp tracked_source_path?(_), do: false

  # -------------------------------------------------------------------
  # Pairing (confidence modifier, orthogonal to which family fired)
  # -------------------------------------------------------------------

  defp paired_with_failed_edit?(tool_use_events, idx, path, result_errors) do
    window_start = max(0, idx - @pairing_lookback)
    window = Enum.slice(tool_use_events, window_start, idx - window_start)

    Enum.any?(window, fn block ->
      block["name"] in @edit_tool_names and
        get_in(block, ["input", "file_path"]) == path and
        Map.get(result_errors, block["id"], false)
    end)
  end

  # tool_use_id -> is_error, from tool_result blocks across the whole
  # window (a result can land in the message right after its call).
  defp build_result_index(messages) do
    messages
    |> Enum.flat_map(&tool_result_blocks/1)
    |> Enum.reduce(%{}, fn
      %{"tool_use_id" => id} = block, acc when is_binary(id) ->
        Map.put(acc, id, block["is_error"] == true)

      _, acc ->
        acc
    end)
  end

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

  defp tool_result_blocks(%{data: data}) do
    data
    |> get_in(["message", "content"])
    |> List.wrap()
    |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_result"))
  end

  defp tool_result_blocks(_), do: []
end
