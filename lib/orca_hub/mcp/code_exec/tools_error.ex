defmodule Tools.Error do
  @moduledoc """
  Raised when a tool called from inside `run_elixir` returns an MCP error
  envelope (`isError == true`).

  The exception is intentionally named `Tools.Error` (not
  `OrcaHub.MCP.CodeExec.…`) so that the message the model sees reads naturally,
  e.g.:

      ** (Tools.Error) tool github__get_issue failed: repo not found

  It carries the tool `name` and the `upstream` error text pulled from the
  result's `content`. Failures are surfaced as exceptions (rather than a result
  tuple) so that tool calls compose cleanly with `|>` and `Enum` in
  model-authored code; `Tools.try_call/2` is the explicit `{:ok, _} | {:error,
  _}` escape hatch for `with`-style handling.
  """
  defexception [:name, :upstream, :message]

  @impl true
  def exception(opts) do
    name = Keyword.get(opts, :name, "unknown")
    upstream = Keyword.get(opts, :upstream, "")
    %__MODULE__{name: name, upstream: upstream, message: "tool #{name} failed: #{upstream}"}
  end
end
