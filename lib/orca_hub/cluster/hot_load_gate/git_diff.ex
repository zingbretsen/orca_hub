defmodule OrcaHub.Cluster.HotLoadGate.GitDiff do
  @moduledoc """
  Impure helper: turns a git range into the change list
  `OrcaHub.Cluster.HotLoadGate.classify/2` expects.

  This exists so the gate itself can stay pure. Everything that shells out
  lives here and nowhere else — do not call `System.cmd/3` from the gate.

  Intentionally has NO tests. It is a shell-out wrapper whose only logic is
  argument assembly and `--name-status` parsing; a test of it would be a
  test of `git`, and mocking `git` would test the mock. The classification
  logic it feeds is the part under test.

  One `git diff` per changed file is deliberate: the gate attributes every
  reason to a specific path, so the diff text has to arrive already split
  per file rather than as one combined blob.
  """

  @doc """
  Changes between `base` and `head` (default: working tree), ready for
  `HotLoadGate.classify/2`.

  Returns `{:ok, changes}` or `{:error, message}`. `:dir` selects the repo
  (default: the current working directory).
  """
  @spec changes(String.t(), keyword) :: {:ok, [map]} | {:error, String.t()}
  def changes(base, opts \\ []) when is_binary(base) do
    dir = Keyword.get(opts, :dir, File.cwd!())
    head = Keyword.get(opts, :head)
    range = if head, do: [base, head], else: [base]

    with {:ok, listing} <- git(["diff", "--name-status", "--no-renames" | range], dir) do
      {:ok, Enum.map(parse_name_status(listing), &attach_diff(&1, range, dir))}
    end
  end

  defp attach_diff(%{path: path} = change, range, dir) do
    case git(["diff", "--unified=8", "--no-color"] ++ range ++ ["--", path], dir) do
      {:ok, text} -> Map.put(change, :diff, text)
      {:error, _} -> Map.put(change, :diff, nil)
    end
  end

  defp parse_name_status(listing) do
    listing
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn line ->
      case String.split(line, "\t", parts: 2) do
        [code, path] -> [%{path: String.trim(path), status: status(code)}]
        _ -> []
      end
    end)
  end

  defp status("A" <> _), do: :added
  defp status("D" <> _), do: :deleted
  defp status("M" <> _), do: :modified
  defp status(_), do: :unknown

  defp git(args, dir) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, "git #{Enum.join(args, " ")} exited #{code}: #{String.trim(out)}"}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end
end
