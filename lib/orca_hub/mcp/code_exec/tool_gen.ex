defmodule OrcaHub.MCP.CodeExec.ToolGen do
  @moduledoc """
  Generates **callable named Elixir functions** from the live tool registry, in
  memory only (`Module.create/3`) — no files are written to disk.

  ## What gets generated

  A single global root module (default `Tools`) plus one submodule per upstream
  prefix:

    * First-party tools (`OrcaHub.MCP.Tools.list/0`) — flat on the root:
      `Tools.send_message_to_session/1`, `Tools.open_file/1`, ...
    * Upstream tools (`OrcaHub.MCP.UpstreamClient.list_tools/0`, namespaced
      `github__get_issue`) — grouped by prefix into a submodule:
      `Tools.Github.get_issue/1`.

  Plus generic helpers on the root module:

    * `Tools.call(name, args)`      — dispatch by raw MCP name, **faithful**
      MCP envelope (escape hatch)
    * `Tools.try_call(name, args)`  — `{:ok, value} | {:error, reason}`
    * `Tools.search(query)`         — fuzzy search tool names/descriptions
    * `Tools.schema(name)`          — a tool's JSON input schema
    * `Tools.list()`                — all `{name, description}`
    * `Tools.text(result)` / `Tools.json(result)` — unwrap a raw envelope

  ## State threading

  Unlike the spike, **no per-session `state` is baked into the module** (that
  would force a per-session module name and grow the never-GC'd atom table, or
  churn a global module per session). Instead a single global `Tools` module is
  generated once and regenerated only when the live registry changes (see
  `OrcaHub.MCP.CodeExec.Generator`). The generated functions read the caller's
  MCP state from the process dictionary (`OrcaHub.MCP.CodeExec.get_state/0`),
  which the sandbox installs in the eval Task before running.

  The `:dispatcher` option is a test seam: it is baked into the `dispatch/3`
  call so tests can inject canned tool results without a live upstream. The
  unwrap/raise semantics (`Dispatcher.invoke!/3`, `try/3`) are always the real
  ones.
  """

  alias OrcaHub.MCP.CodeExec.Dispatcher

  @default_root Tools

  @doc """
  Generate the named function modules from the (live or supplied) registry.

  Options:

    * `:root`       — root module atom (default `Tools`)
    * `:dispatcher` — module exposing `dispatch(name, args, state)` baked into
      the generated functions (default `OrcaHub.MCP.CodeExec.Dispatcher`)
    * `:tools`      — override the tool list (for tests); defaults to the live
      first-party + upstream registries

  Returns `{root_module, [generated_module, ...]}`.
  """
  def generate(opts \\ []) do
    root = Keyword.get(opts, :root, @default_root)
    dispatcher = Keyword.get(opts, :dispatcher, Dispatcher)
    tools = Keyword.get_lazy(opts, :tools, &live_tools/0)

    {first_party, upstream} = Enum.split_with(tools, &(not String.contains?(&1["name"], "__")))

    upstream_by_prefix =
      Enum.group_by(upstream, fn t -> t["name"] |> String.split("__", parts: 2) |> hd() end)

    # Redefining the global `Tools` module on each regeneration is intentional;
    # suppress the (expected) "redefining module" warning around the creates.
    without_module_conflict_warnings(fn ->
      # Submodule per upstream prefix: Tools.Github.get_issue/1
      sub_modules =
        Enum.map(upstream_by_prefix, fn {prefix, prefix_tools} ->
          mod = Module.concat(root, Macro.camelize(prefix))
          create_module(mod, prefix_tools, &strip_prefix/1, dispatcher)
        end)

      # Root module: flat first-party funcs + generic helpers
      create_root(root, first_party, tools, dispatcher)

      {root, [root | sub_modules]}
    end)
  end

  defp without_module_conflict_warnings(fun) do
    previous = Code.compiler_options()[:ignore_module_conflict]
    Code.compiler_options(ignore_module_conflict: true)

    try do
      fun.()
    after
      Code.compiler_options(ignore_module_conflict: previous)
    end
  end

  @doc "Fetch the live registry (first-party full set + upstream cache)."
  def live_tools do
    OrcaHub.MCP.Tools.list() ++ OrcaHub.MCP.UpstreamClient.list_tools()
  end

  @doc """
  A stable signature of the current registry. The `Generator` regenerates the
  `Tools` surface only when this changes, so the global module is not churned on
  every `run_elixir` call.
  """
  def signature(tools \\ nil) do
    (tools || live_tools())
    |> Enum.map(& &1["name"])
    |> Enum.sort()
    |> :erlang.phash2()
  end

  # ── module builders ──────────────────────────────────────────────────

  defp create_module(mod, tools, name_fun, dispatcher) do
    funs = Enum.map(tools, &tool_fun(&1, name_fun, dispatcher))
    body = quote do: (unquote_splicing(funs))
    Module.create(mod, body, Macro.Env.location(__ENV__))
    mod
  end

  defp create_root(root, first_party, all_tools, dispatcher) do
    funs = Enum.map(first_party, &tool_fun(&1, fn tool -> tool["name"] end, dispatcher))
    helpers = root_helpers(all_tools, dispatcher)
    body = quote do: (unquote_splicing(funs ++ helpers))
    Module.create(root, body, Macro.Env.location(__ENV__))
    root
  end

  # One named function per tool, e.g. `def get_issue(args \\ %{})`, dispatching
  # the *raw* MCP name through the baked-in dispatcher and auto-unwrapping the
  # result (raises Tools.Error on isError). MCP state comes from the pdict.
  defp tool_fun(tool, name_fun, dispatcher) do
    raw_name = tool["name"]
    fun_name = String.to_atom(name_fun.(tool))
    description = tool["description"] || ""

    quote do
      @doc unquote(description)
      def unquote(fun_name)(args \\ %{}) do
        unquote(Dispatcher).invoke!(unquote(dispatcher), unquote(raw_name), args)
      end
    end
  end

  defp root_helpers(all_tools, dispatcher) do
    # A compact, escapable registry index for search/schema/list.
    index =
      Enum.map(all_tools, fn t ->
        %{name: t["name"], description: t["description"] || "", schema: t["inputSchema"] || %{}}
      end)

    [
      quote do
        @doc "Dispatch any tool by raw MCP name — faithful MCP envelope (escape hatch)."
        def call(name, args \\ %{}) when is_binary(name) do
          unquote(Dispatcher).raw(unquote(dispatcher), name, args)
        end
      end,
      quote do
        @doc "Dispatch any tool by raw MCP name — `{:ok, value} | {:error, reason}`."
        def try_call(name, args \\ %{}) when is_binary(name) do
          unquote(Dispatcher).try(unquote(dispatcher), name, args)
        end
      end,
      quote do
        @doc "All tools as {name, description} tuples."
        def list do
          Enum.map(unquote(Macro.escape(index)), fn t -> {t.name, t.description} end)
        end
      end,
      quote do
        @doc "Fuzzy search tool names + descriptions (case-insensitive)."
        def search(query) when is_binary(query) do
          q = String.downcase(query)

          unquote(Macro.escape(index))
          |> Enum.filter(fn t ->
            String.contains?(String.downcase(t.name), q) or
              String.contains?(String.downcase(t.description), q)
          end)
          |> Enum.map(fn t -> {t.name, t.description} end)
        end
      end,
      quote do
        @doc "Fetch a tool's JSON input schema by raw MCP name."
        def schema(name) when is_binary(name) do
          case Enum.find(unquote(Macro.escape(index)), &(&1.name == name)) do
            nil -> nil
            t -> t.schema
          end
        end
      end,
      quote do
        @doc "Extract the concatenated text content from a raw MCP result map."
        def text(%{"content" => content}) when is_list(content) do
          content
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map_join("\n", & &1["text"])
        end

        def text(other), do: inspect(other)
      end,
      quote do
        @doc "Extract text from a raw MCP result and JSON-decode it."
        def json(result), do: result |> text() |> Jason.decode!()
      end
    ]
  end

  # github__get_issue -> get_issue
  defp strip_prefix(tool), do: tool["name"] |> String.split("__", parts: 2) |> List.last()
end
