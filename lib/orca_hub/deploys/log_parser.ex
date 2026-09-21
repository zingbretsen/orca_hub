defmodule OrcaHub.Deploys.LogParser do
  @moduledoc """
  Turn a deploy job's log into structured feedback — which steps ran, which
  were skipped, what failed, and what *warned without failing*.

  See `.context/deploy-jobs-design.md` §2.6. The honest contract: we get
  "which step failed" from the exit code, a handful of regexes over the log,
  and the last N bytes of it. Nothing more — **and that requires zero
  changes to the deploy scripts**, which live in a private repo we were told
  to leave alone.

  It works better than it sounds because of one surveyed fact: all three
  scripts share a byte-identical `banner()`
  (`deploy-orca-hub.sh:360-365`, `deploy-content-studio.sh:326-331`,
  `deploy-video-search.sh:209-214`):

      echo ""
      echo "=============================================================="
      echo ">>> $*"
      echo "=============================================================="

  so one parser covers every target today, and any future script that copies
  the same helper.

  ## What it extracts

    * `steps_seen` — every `>>> <step>` in order. Not de-duplicated: a step
      banner printed twice really did happen twice.
    * `last_step` — the final element. **The step it REACHED, not
      necessarily the step that failed** (under `set -e` they usually
      coincide; a warn-only failure inside a completed step does not).
    * `skipped_steps` — `--- SKIPPED: <what> ---`, emitted by
      `step_skipped()` (orca-hub L367-370, video-search L215-218) and by one
      inline `echo` in content-studio (L796).
    * `errors` — lines starting `ERROR:`, `FATAL:` or `  FAIL:`, plus every
      line inside the `####…####` block that `fatal()` frames on stderr
      (content-studio L341-348, video-search L221-228). stderr is in the
      same log because the job wrapper redirects `2>&1`
      (`Jobs.Launcher` — `> log 2>&1`).
    * `warnings` — lines starting `WARNING:` or `  TIMEOUT:`, plus the `!! `
      lines of content-studio's framed `warn()` (L333-339).
    * `log_tail` — the last `:log_tail_bytes` bytes, UTF-8-repaired.

  ## Why `warnings` is separate, and load-bearing

  Six paths in `deploy-orca-hub.sh` warn and continue — the image-tag and
  buildx-cache prunes, all three k3s `/api/version` polls, the whole `mini`
  stage and the whole `gb10` stage (§1.1). **A deploy can therefore exit 0
  with a completely failed gb10 stage.** Reporting `warnings[]` as a
  first-class field is the thing that stops a model reading "exit 0" as
  "everything worked".

  ## Deliberate limits

    * Parsing runs over the **whole** log; only `log_tail` is truncated.
    * The tail is truncated by BYTES, so its first line may be cut mid-way —
      same convention as `check_job`'s existing tail.
  """

  @step_re ~r/^>>> (.+)$/
  @skipped_re ~r/^--- SKIPPED: (.+) ---\s*$/
  @error_re ~r/^(?:ERROR|FATAL|  FAIL):/
  @warning_re ~r/^(?:WARNING|  TIMEOUT):/

  # fatal() frames its message in 76 '#'; warn() frames its own in 76 '!'.
  # Matched loosely (8+) so a frame-width change upstream does not silently
  # stop the block from being recognised.
  @fatal_frame_re ~r/^\#{8,}$/
  @warn_frame_re ~r/^!{8,}$/
  @warn_line_re ~r/^!! (.*)$/

  @default_tail_bytes 4000

  @doc """
  Parse a whole deploy log.

  Options:

    * `:log_tail_bytes` — bytes of tail to return (default #{@default_tail_bytes}).
      `nil` returns the whole log.

  Returns a map with `:steps_seen`, `:last_step`, `:skipped_steps`,
  `:errors`, `:warnings` and `:log_tail`.
  """
  def parse(log, opts \\ [])

  def parse(nil, opts), do: parse("", opts)

  def parse(log, opts) when is_binary(log) do
    lines = String.split(log, "\n")

    steps = capture_all(lines, @step_re)

    %{
      steps_seen: steps,
      last_step: List.last(steps),
      skipped_steps: capture_all(lines, @skipped_re),
      errors: errors(lines),
      warnings: warnings(lines),
      log_tail: tail(log, Keyword.get(opts, :log_tail_bytes, @default_tail_bytes))
    }
  end

  @doc """
  The last `bytes` bytes of `log`, repaired to valid UTF-8.

  Slicing at a byte offset can land inside a multi-byte character (every
  step banner in `deploy-orca-hub.sh` contains an em dash), which would make
  the result unencodable as JSON — so leading continuation bytes are
  dropped and any remaining invalid bytes are scrubbed.
  """
  def tail(log, bytes \\ @default_tail_bytes)

  def tail(log, nil) when is_binary(log), do: scrub(log)

  def tail(log, bytes) when is_binary(log) and is_integer(bytes) and bytes > 0 do
    size = byte_size(log)

    if size <= bytes do
      scrub(log)
    else
      log |> binary_part(size - bytes, bytes) |> scrub()
    end
  end

  def tail(log, _bytes) when is_binary(log), do: ""

  defp capture_all(lines, regex) do
    Enum.flat_map(lines, fn line ->
      case Regex.run(regex, strip_cr(line)) do
        [_, captured] -> [String.trim_trailing(captured)]
        _ -> []
      end
    end)
  end

  # Error lines, plus the body of every `####`-framed fatal() block. A
  # fatal message usually also starts with "FATAL:", so it matches twice —
  # hence the uniq, which keeps first-seen order.
  defp errors(lines) do
    lines
    |> collect(@error_re, @fatal_frame_re, fn line -> line end)
    |> Enum.uniq()
  end

  # warn() strips no prefix of its own: it emits "!! <line>" per line inside
  # a '!'-framed block. §2.6 only names WARNING:/  TIMEOUT: (both of which
  # orca-hub uses), but content-studio's warnings are exclusively the framed
  # form, so they would otherwise be invisible for that target.
  defp warnings(lines) do
    lines
    |> collect(@warning_re, @warn_frame_re, fn line ->
      case Regex.run(@warn_line_re, line) do
        [_, rest] -> rest
        _ -> line
      end
    end)
    |> Enum.uniq()
  end

  # One pass: emit any line matching `line_re`, and any non-blank line
  # between an opening and closing `frame_re` delimiter. An unterminated
  # block (a log truncated mid-fatal) collects to the end, which is the
  # useful behaviour.
  defp collect(lines, line_re, frame_re, normalize) do
    {acc, _inside} =
      Enum.reduce(lines, {[], false}, fn raw, {acc, inside} ->
        line = raw |> strip_cr() |> String.trim_trailing()

        cond do
          Regex.match?(frame_re, line) ->
            {acc, not inside}

          inside and line != "" ->
            {[normalize.(line) | acc], inside}

          Regex.match?(line_re, line) ->
            {[line | acc], inside}

          true ->
            {acc, inside}
        end
      end)

    Enum.reverse(acc)
  end

  defp strip_cr(line), do: String.trim_trailing(line, "\r")

  # Drop leading bytes until the binary starts on a character boundary,
  # then remove any remaining invalid sequences.
  defp scrub(binary) do
    trimmed = trim_leading_continuation(binary, 0)

    if String.valid?(trimmed),
      do: trimmed,
      else: trimmed |> do_scrub([]) |> IO.iodata_to_binary()
  end

  # A UTF-8 continuation byte is 0b10xxxxxx; at most three can precede the
  # next character boundary.
  defp trim_leading_continuation(<<byte, rest::binary>>, dropped)
       when byte >= 0x80 and byte <= 0xBF and dropped < 3,
       do: trim_leading_continuation(rest, dropped + 1)

  defp trim_leading_continuation(binary, _dropped), do: binary

  defp do_scrub(<<>>, acc), do: Enum.reverse(acc)

  defp do_scrub(<<char::utf8, rest::binary>>, acc),
    do: do_scrub(rest, [<<char::utf8>> | acc])

  defp do_scrub(<<_bad, rest::binary>>, acc), do: do_scrub(rest, acc)
end
