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
        kind: :paired_with_failed_edit | :standalone}

  or `nil` if no file-surgery pattern is found. Never raises.

  ## Matcher

  Fires on a `Bash` tool_use command that has ALL of:
    a. a real output redirection `>` or `>>` (a bare `2>&1` / `2>` alone
       does not count);
    b. the redirected input is a text-slicing read (`cat`, `head`,
       `tail`, `sed -n`, `awk`) of a path;
    c. that path passes the tracked-source heuristic (source-file
       extension, not under a build/scratch/log directory).

  `git show`/`cat-file`/`diff`/`archive` are checked and excluded before
  any of the above — that is the SANCTIONED recovery procedure.

  `kind` is `:paired_with_failed_edit` when a failed Edit/Write/MultiEdit
  on the same path appears in the preceding #{@pairing_lookback} tool
  calls, else `:standalone`.
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

              path ->
                %{
                  path: path,
                  command: cmd,
                  kind: classify_kind(tool_use_events, idx, path, result_errors)
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

      not real_output_redirect?(cmd) ->
        nil

      true ->
        case split_at_real_redirect(cmd) do
          nil ->
            nil

          left ->
            case extract_slicing_path(left) do
              nil -> nil
              path -> if tracked_source_path?(path), do: path, else: nil
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
  # Pairing (kind)
  # -------------------------------------------------------------------

  defp classify_kind(tool_use_events, idx, path, result_errors) do
    window_start = max(0, idx - @pairing_lookback)
    window = Enum.slice(tool_use_events, window_start, idx - window_start)

    paired? =
      Enum.any?(window, fn block ->
        block["name"] in @edit_tool_names and
          get_in(block, ["input", "file_path"]) == path and
          Map.get(result_errors, block["id"], false)
      end)

    if paired?, do: :paired_with_failed_edit, else: :standalone
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
