defmodule OrcaHub.MCP.CodeExec.Analyzer do
  @moduledoc """
  Static extraction of the `Tools.*` names a `run_elixir` snippet references,
  without evaluating it.

  This is step 1 of a two-step plan: a *static* best-effort read of what a
  persisted snippet's source text calls, used purely to make the message feed
  and `get_session_tail` more legible (e.g. "search_sessions, start_session"
  instead of a truncated code preview). It does not know whether the calls
  actually ran, raised, or were reached at all (a snippet can branch) — step 2
  (runtime capture, tracked separately) is out of scope here.

  Because this runs at render time on arbitrary model-authored, persisted
  input, it must **never raise** — any parse failure or unexpected shape
  simply yields an empty result.

  ## How it works

  1. Parse with `Code.string_to_quoted/1` (same front door `Sandbox.parse/1`
     uses). On failure, return an empty result.
  2. Walk the AST (`Macro.prewalk/3`, mirroring `Sandbox.check/1`) looking for
     remote calls to the generated `Tools` namespace:

       * `Tools.foo(args)` — a real generated tool function. Captured as `foo`.
       * `Tools.call("name", ...)` / `Tools.try_call("name", ...)` — the
         escape-hatch dispatchers (see `OrcaHub.MCP.CodeExec.ToolGen`). When
         the first argument is a string *literal*, that's the real tool being
         dispatched — captured the same as a named call. When it isn't (a
         variable, an interpolated string, ...), we can't know statically
         which tool it reaches, so we record `"call"`/`"try_call"` itself as
         a meta hit, so a reader at least sees a dynamic dispatch happened.
       * `Tools.search(...)`, `Tools.list()`, `Tools.schema(...)` — discovery
         helpers, not tool dispatches. Always recorded as meta hits.

  A snippet piped into a `Tools.*` call (`x |> Tools.foo()`) is still found —
  `Macro.prewalk/3` visits the pipe's right-hand side same as any other node,
  and the args list at that AST location is whatever explicit args follow
  `foo` (the piped-in value isn't part of the args list until the `|>` macro
  is expanded, which we deliberately don't do here).

  ## Result shape

  `analyze/1` returns `%{tools: [String.t()], meta: [String.t()]}`, both
  deduped and in first-appearance order. `tool_calls/1` is a convenience that
  returns just the `:tools` list, for callers that don't care about the
  discovery/dispatch helpers.
  """

  @dispatch_helpers ~w(call try_call)a
  @discovery_helpers ~w(search list schema)a

  @doc """
  Extract the `Tools.*` names referenced by `code`, split into real tool
  dispatches (`:tools`) and discovery/dispatch helpers (`:meta`). Returns
  `%{tools: [], meta: []}` for anything that isn't a binary or fails to
  parse — this function never raises.
  """
  def analyze(code) when is_binary(code) do
    case Code.string_to_quoted(code) do
      {:ok, ast} -> ast |> collect() |> split()
      {:error, _reason} -> empty()
    end
  rescue
    _ -> empty()
  end

  def analyze(_other), do: empty()

  @doc "Convenience: just the real tool names (see `analyze/1`)."
  def tool_calls(code), do: analyze(code).tools

  defp empty, do: %{tools: [], meta: []}

  defp collect(ast) do
    {_ast, hits} =
      Macro.prewalk(ast, [], fn node, acc -> {node, extract(node, acc)} end)

    Enum.reverse(hits)
  end

  # Tools.call("name", ...) / Tools.try_call("name", ...) with a literal
  # string first argument — the real tool being dispatched.
  defp extract(
         {{:., _, [{:__aliases__, _, [:Tools]}, fun]}, _, [name | _]},
         acc
       )
       when fun in @dispatch_helpers and is_binary(name) do
    [{:tool, name} | acc]
  end

  # Same dispatchers, but the target isn't statically known — record the
  # dispatcher name itself so a reader sees a dynamic dispatch happened.
  defp extract(
         {{:., _, [{:__aliases__, _, [:Tools]}, fun]}, _, args},
         acc
       )
       when fun in @dispatch_helpers and is_list(args) do
    [{:meta, Atom.to_string(fun)} | acc]
  end

  # Discovery helpers — never a tool dispatch.
  defp extract(
         {{:., _, [{:__aliases__, _, [:Tools]}, fun]}, _, args},
         acc
       )
       when fun in @discovery_helpers and is_list(args) do
    [{:meta, Atom.to_string(fun)} | acc]
  end

  # A plain named call: Tools.foo(args) — including a zero-arg `Tools.foo()`.
  defp extract(
         {{:., _, [{:__aliases__, _, [:Tools]}, fun]}, _, args},
         acc
       )
       when is_atom(fun) and is_list(args) do
    [{:tool, Atom.to_string(fun)} | acc]
  end

  defp extract(_node, acc), do: acc

  defp split(hits) do
    %{
      tools:
        hits |> Enum.filter(&match?({:tool, _}, &1)) |> Enum.map(&elem(&1, 1)) |> Enum.uniq(),
      meta: hits |> Enum.filter(&match?({:meta, _}, &1)) |> Enum.map(&elem(&1, 1)) |> Enum.uniq()
    }
  end
end
