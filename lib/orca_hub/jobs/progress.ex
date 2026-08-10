defmodule OrcaHub.Jobs.Progress do
  @moduledoc """
  Samples a job's DECLARED progress metric — OrcaHub never infers one.

  This exists because of a real incident: a worker downloading a 46GB GGUF
  file switched partway through from a single `curl` writing `.partial` to
  8 ranged `curl`s writing `.part0`-`.part7`. A generic "watch this file's
  size" heuristic would have seen `.partial` frozen and reported a healthy,
  actively-progressing download as dead. There is deliberately no attempt
  here to auto-detect "the right file to watch" or to judge staleness —
  `progress_updated_at`'s age is surfaced to the caller (via `check_job`)
  and the AGENT judges whether that's healthy for the metric IT declared.

  Two declarable kinds, set via `start_job`/`update_job_progress_metric`:

    * `"file_bytes"` — stat `progress_path`; `progress_value` = current
      size, `progress_total` = `progress_expect_bytes` (if given).
    * `"command"` — run `progress_command` (bounded — see
      `@command_timeout_ms`) and parse its stdout as either a bare number,
      `"value/total"`, or a JSON object `{"value":, "total":, "note":}`.
      Falls back to storing raw non-numeric output as `progress_note` so a
      job can report free-text status ("downloading part 3/8") even without
      a parseable number.

  A job re-declaring its metric (`update_job_progress_metric`) is a plain
  DB column update — `OrcaHub.JobWatcher` re-reads these columns fresh from
  the job row on every poll tick rather than caching them at watch-start,
  so a mid-flight re-declaration takes effect on the very next tick with no
  IPC to the watcher process required.
  """

  require Logger

  @default_command_timeout_ms 5_000

  defp command_timeout_ms,
    do:
      Application.get_env(
        :orca_hub,
        :job_progress_command_timeout_ms,
        @default_command_timeout_ms
      )

  @doc """
  Sample the metric `job` currently declares. Returns `{:ok, attrs}` (a map
  ready to pass to `update_job/2`), `:unchanged` (no metric declared, or a
  transient sampling failure not worth recording), or `{:error, reason}`.
  """
  def sample(%{progress_kind: "file_bytes", progress_path: path} = job)
      when is_binary(path) and path != "" do
    case File.stat(path) do
      {:ok, %{size: size}} ->
        {:ok, progress_attrs(size * 1.0, expect_total(job), nil)}

      {:error, _reason} ->
        :unchanged
    end
  end

  def sample(%{progress_kind: "command", progress_command: cmd})
      when is_binary(cmd) and cmd != "" do
    case run_bounded(cmd) do
      {:ok, output} -> {:ok, progress_attrs_from_output(output)}
      {:error, _reason} -> :unchanged
    end
  end

  def sample(_job), do: :unchanged

  defp expect_total(%{progress_expect_bytes: bytes}) when is_integer(bytes), do: bytes * 1.0
  defp expect_total(_job), do: nil

  defp progress_attrs(value, total, note) do
    %{
      progress_value: value,
      progress_total: total,
      progress_note: note,
      progress_updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp progress_attrs_from_output(output) do
    trimmed = String.trim(output)

    cond do
      parsed = parse_json_progress(trimmed) -> parsed
      parsed = parse_ratio(trimmed) -> parsed
      parsed = parse_bare_float(trimmed) -> parsed
      true -> progress_attrs(nil, nil, String.slice(trimmed, 0, 500))
    end
  end

  defp parse_json_progress(text) do
    with {:ok, %{} = decoded} <- Jason.decode(text) do
      progress_attrs(
        numeric(decoded["value"]),
        numeric(decoded["total"]),
        decoded["note"]
      )
    else
      _ -> nil
    end
  end

  defp numeric(n) when is_number(n), do: n * 1.0
  defp numeric(_), do: nil

  defp parse_ratio(text) do
    case Regex.run(~r/^([0-9]+(?:\.[0-9]+)?)\s*\/\s*([0-9]+(?:\.[0-9]+)?)$/, text) do
      [_, value, total] -> progress_attrs(float_parse(value), float_parse(total), nil)
      nil -> nil
    end
  end

  defp parse_bare_float(text) do
    case float_parse(text) do
      nil -> nil
      value -> progress_attrs(value, nil, nil)
    end
  end

  defp float_parse(text) do
    case Float.parse(text) do
      {value, _rest} -> value
      :error -> nil
    end
  end

  defp run_bounded(cmd) do
    task = Task.async(fn -> System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) end)

    case Task.yield(task, command_timeout_ms()) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, _exit_code}} -> {:ok, output}
      _timeout_or_shutdown -> {:error, :progress_command_timeout}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
