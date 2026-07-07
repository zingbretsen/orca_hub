defmodule OrcaHub.MCP.CodeExec.Dispatcher do
  @moduledoc """
  Routing + result-unwrapping for the generated `Tools.*` surface.

  ## Routing (`dispatch/3`)

  The single dispatch entry point. It does **not** reimplement routing: it
  reuses the exact decision the live MCP server makes in `OrcaHub.MCP.Server` —

    * upstream tool (namespaced, e.g. `github__get_issue`) →
      `OrcaHub.MCP.UpstreamClient.call_tool/3` (passing the caller's
      `orca_session_id` so session-scoped upstreams route correctly)
    * otherwise → `OrcaHub.MCP.Tools.call/3`

  and returns the raw MCP result map (`%{"content" => [...], "isError" => bool}`).
  `dispatch/3` is the swappable seam: `ToolGen` bakes the dispatcher module into
  the generated functions, so tests can inject a stub returning canned envelopes
  without a live upstream.

  ## Unwrapping (`unwrap!/2`, `try/3`)

  The generated **named** functions (`Tools.github__get_issue/1`) auto-unwrap the
  MCP envelope and RAISE on `isError`:

    * text content → the concatenated string;
    * JSON content (text that decodes to a map/list) → the decoded term;
    * `isError == true` → `raise Tools.Error` carrying the tool name + the
      upstream error text.

  This makes tool calls compose with `|>` / `Enum`. The faithful full envelope
  is still reachable via `Tools.call/2`, and `Tools.try_call/2` (→ `try/3`)
  returns `{:ok, val} | {:error, reason}` for explicit `with`-style handling.
  """

  alias OrcaHub.MCP.UpstreamClient
  alias OrcaHub.MCP.CodeExec

  # NOTE: `Tools` is intentionally NOT aliased to `OrcaHub.MCP.Tools` here — in
  # this module `Tools.Error` must resolve to the top-level exception module
  # (the one the model sees in error messages), so first-party dispatch uses the
  # fully-qualified `OrcaHub.MCP.Tools.call/3`.

  @doc """
  Dispatch a tool call by raw MCP name through the existing MCP path.

  `state` is the same `%{orca_session_id: ..., orchestrator: ...}` map the live
  MCP server threads into `OrcaHub.MCP.Tools.call/3`.
  """
  def dispatch(name, args, state) when is_binary(name) and is_map(args) do
    if UpstreamClient.upstream_tool?(name) do
      UpstreamClient.call_tool(name, args, orca_session_id: state[:orca_session_id])
    else
      OrcaHub.MCP.Tools.call(name, args, state)
    end
  end

  @doc """
  Dispatch `name` (via `dispatcher`) using the process-installed MCP state, then
  auto-unwrap the result. Raises `Tools.Error` on an error envelope. Used by the
  generated named functions.
  """
  def invoke!(dispatcher, name, args) do
    dispatcher.dispatch(name, args, CodeExec.get_state()) |> unwrap!(name)
  end

  @doc "Like `invoke!/3` but returns `{:ok, value} | {:error, reason}`."
  def try(dispatcher, name, args) do
    {:ok, invoke!(dispatcher, name, args)}
  rescue
    e in Tools.Error -> {:error, e.message}
    e -> {:error, Exception.message(e)}
  end

  @doc "Dispatch `name` (via `dispatcher`) and return the faithful MCP envelope."
  def raw(dispatcher, name, args) do
    dispatcher.dispatch(name, args, CodeExec.get_state())
  end

  @doc """
  Auto-unwrap an MCP result map for `name`.

    * `isError == true` → `raise Tools.Error`
    * content that decodes to a JSON map/list → the decoded term
    * otherwise → the concatenated text string
  """
  def unwrap!(%{"isError" => true} = result, name) do
    raise Tools.Error, name: name, upstream: extract_text(result)
  end

  def unwrap!(%{"content" => content}, _name) when is_list(content) do
    text = text_from_content(content)

    case Jason.decode(text) do
      {:ok, term} when is_map(term) or is_list(term) -> term
      _ -> text
    end
  end

  def unwrap!(other, _name), do: other

  defp extract_text(%{"content" => content}) when is_list(content), do: text_from_content(content)
  defp extract_text(other), do: inspect(other)

  defp text_from_content(content) do
    content
    |> Enum.filter(&(&1["type"] == "text"))
    |> Enum.map_join("\n", & &1["text"])
  end
end
