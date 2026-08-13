defmodule OrcaHub.PromptGolden do
  @moduledoc """
  Byte-pinned golden fixtures for backend system prompts.

  `OrcaHub.Backend.SharedPrompts` is shared by `Backend.Claude`,
  `Backend.Codex` and `Backend.Pi`. The pi session-forking work
  (`pi_fork_spec.md` §5) makes pi's `system_prompt/1` a pure function of its
  flags — a pi-only change that must land WITHOUT moving a single byte of the
  Claude or Codex prompt, since any edit to a shared fragment would silently
  reword every Claude/Codex session's system prompt.

  These goldens are that guardrail: each backend renders its `system_prompt/1`
  across a flag matrix under fully deterministic inputs, and the exact bytes
  are committed. A shared-fragment edit that leaks into Claude/Codex fails
  loudly, naming the case.

  ## Determinism

  Everything the prompt reads is pinned:

  - `session_id/0` — a fixed UUID, never `Ecto.UUID.generate/0`, since the id
    is interpolated into several fragments.
  - `directory/0` — a path that does not exist, so
    `SharedPrompts.context_files_prompt/1` returns `nil` instead of inlining
    whatever `.context/*.md` happens to be on disk.
  - `SharedPrompts.open_issues_prompt/1` does a **live DB query**. The fixed
    session id above owns no issues, so it returns `nil` — the golden tests
    assert that precondition explicitly rather than assuming it, so a dev-DB
    row can never silently rewrite the fixture's meaning.

  ## Regenerating

  Only when a Claude/Codex prompt change is *intended*:

      ORCA_REGENERATE_PROMPT_GOLDENS=1 mix test test/orca_hub/backend/claude_test.exs

  then review the resulting `test/support/fixtures/prompt_goldens/*.txt` diff
  as the actual prompt change it is.
  """

  @goldens_dir Path.expand("fixtures/prompt_goldens", __DIR__)

  @session_id "00000000-0000-4000-8000-0000000000fe"
  @directory "/nonexistent-prompt-golden-dir"
  @issue_key "ORCA-1"

  @doc "The one fixed session id every golden case renders with."
  def session_id, do: @session_id

  @doc "A directory guaranteed not to exist (keeps `context_files_prompt/1` nil)."
  def directory, do: @directory

  @doc "The fixed issue key used by the `issue_key` half of the matrix."
  def issue_key, do: @issue_key

  @doc """
  The shared flag matrix: orchestrator × code_exec × commit_trailer ×
  issue_key — the four flags every backend's `system_prompt/1` branches on.
  Returns `[{case_name, ctx_overrides}]`; `extra` cases are appended verbatim
  for backend-specific dimensions (Claude's no-MCP / api_run modes).
  """
  def matrix(extra \\ []) do
    base =
      for orchestrator <- [false, true],
          code_exec <- [false, true],
          commit_trailer <- [false, true],
          issue_key <- [nil, @issue_key] do
        name =
          "orchestrator=#{orchestrator} code_exec=#{code_exec} " <>
            "commit_trailer=#{commit_trailer} issue_key=#{issue_key || "nil"}"

        {name,
         %{
           orchestrator: orchestrator,
           code_exec: code_exec,
           commit_trailer: commit_trailer,
           issue_key: issue_key
         }}
      end

    base ++ extra
  end

  @doc """
  The pinned ctx every golden case renders with, plus that case's overrides.
  Deliberately NOT the per-test `ctx/1` helpers in the backend test files —
  those randomize `session_id`/`directory`, which a golden cannot tolerate.
  """
  def golden_ctx(overrides) do
    %{
      session_id: @session_id,
      project_id: nil,
      claude_session_id: nil,
      directory: @directory,
      model: nil,
      orchestrator: false,
      code_exec: false,
      db_node: nil,
      engine: :streaming,
      backend_state: %{}
    }
    |> Map.merge(Map.new(overrides))
  end

  @doc "Renders every case into one delimited document (the on-disk format)."
  def render(cases, render_fun) do
    Enum.map_join(cases, "", fn {name, overrides} ->
      "===== CASE #{name} =====\n" <>
        render_fun.(golden_ctx(overrides)) <> "\n===== END CASE =====\n"
    end)
  end

  @doc "Inverse of `render/2` — parses a golden document back into %{case_name => text}."
  def parse(document) do
    # `name` is deliberately [^\n]* rather than `.` — the /s flag below makes
    # `.` match newlines, which would otherwise swallow the whole document
    # into the first case's name.
    ~r/^===== CASE (?<name>[^\n]*) =====\n(?<body>.*?)\n===== END CASE =====\n/ms
    |> Regex.scan(document, capture: [:name, :body])
    |> Map.new(fn [name, body] -> {name, body} end)
  end

  @doc false
  def path(name), do: Path.join(@goldens_dir, name <> ".txt")

  @doc false
  def regenerate?, do: System.get_env("ORCA_REGENERATE_PROMPT_GOLDENS") == "1"

  @doc false
  def write!(name, contents) do
    File.mkdir_p!(@goldens_dir)
    File.write!(path(name), contents)
  end

  @doc false
  def read(name) do
    case File.read(path(name)) do
      {:ok, contents} -> contents
      {:error, _} -> ""
    end
  end

  @doc """
  Compares a freshly-rendered document against the committed golden, case by
  case, so a failure names the ONE case that drifted and shows the first
  differing line instead of diffing a 100KB blob.

  Returns `:ok`, or a human-readable failure string for the caller to `flunk/1`.
  """
  def compare(name, rendered) do
    actual = parse(rendered)
    golden = parse(read(name))

    cond do
      map_size(golden) == 0 ->
        {:error, "no golden committed for #{name} — #{regen_hint(name)}"}

      Map.keys(actual) != Map.keys(golden) ->
        {:error,
         """
         #{name} golden case set drifted.
           only in code:   #{inspect(Map.keys(actual) -- Map.keys(golden))}
           only in golden: #{inspect(Map.keys(golden) -- Map.keys(actual))}
         #{regen_hint(name)}
         """}

      true ->
        actual
        |> Enum.find(fn {case_name, text} -> Map.fetch!(golden, case_name) != text end)
        |> case do
          nil -> :ok
          {case_name, text} -> {:error, mismatch_report(name, case_name, text, golden)}
        end
    end
  end

  defp mismatch_report(name, case_name, actual_text, golden) do
    expected_text = Map.fetch!(golden, case_name)

    """
    #{name} system prompt drifted from its committed golden.

      case: #{case_name}

    #{first_difference(expected_text, actual_text)}

    If this change is INTENTIONAL, #{regen_hint(name)}
    If it is not, a shared fragment (lib/orca_hub/backend/shared_prompts.ex)
    was mutated where it should have been extended — see this module's docs.
    """
  end

  defp first_difference(expected, actual) do
    expected_lines = String.split(expected, "\n")
    actual_lines = String.split(actual, "\n")

    index =
      Enum.find_index(0..max(length(expected_lines), length(actual_lines)), fn i ->
        Enum.at(expected_lines, i) != Enum.at(actual_lines, i)
      end)

    """
      first differing line: #{index + 1}
        golden: #{inspect(Enum.at(expected_lines, index))}
        actual: #{inspect(Enum.at(actual_lines, index))}
    """
  end

  defp regen_hint(name) do
    "regenerate with: ORCA_REGENERATE_PROMPT_GOLDENS=1 mix test " <>
      "test/orca_hub/backend/#{name}_test.exs — and review the fixture diff " <>
      "as the prompt change it is."
  end
end
