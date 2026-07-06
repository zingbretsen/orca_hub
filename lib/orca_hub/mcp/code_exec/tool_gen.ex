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
      `github__get_issue`) — flat on the root under their **raw MCP name**
      (`Tools.github__get_issue/1`, matching what the system prompt and
      `search_tools`/`read_tool` teach), AND grouped by prefix into a
      submodule as sugar: `Tools.Github.get_issue/1`. A tool whose raw name
      isn't a valid Elixir function identifier is skipped (with a
      `Logger.warning`) rather than crashing generation.

  Plus generic helpers on the root module:

    * `Tools.call(name, args)`      — dispatch by raw MCP name, **faithful**
      MCP envelope (escape hatch)
    * `Tools.try_call(name, args)`  — `{:ok, value} | {:error, reason}`
    * `Tools.search(query)`         — ranked keyword search (BM25, see
      `OrcaHub.MCP.CodeExec.ToolSearch`) over tool names/descriptions,
      returning `%{"name" =>, "description" =>, "args" =>}` maps
    * `Tools.schema(name)`          — a tool's JSON input schema
    * `Tools.list()`                — all tools as `%{"name" =>, "description" =>}`
      maps
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

  require Logger

  alias OrcaHub.MCP.CodeExec.{Dispatcher, ToolSearch}

  @default_root Tools

  # Raw MCP tool names are only generated as flat root defs when they're valid
  # Elixir function identifiers (lowercase, underscores, optional trailing ?/!).
  @valid_fun_name ~r/^[a-z_][a-zA-Z0-9_]*[?!]?$/

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

      # Root module: flat first-party + upstream funcs + generic helpers
      create_root(root, first_party, upstream, tools, dispatcher)

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

  @doc """
  Derive an arg-name list from a tool's JSON input schema: property names,
  sorted, with optional ones (not listed in "required") suffixed `?`, e.g.
  `["number?", "repo"]`. Shared by the generated `Tools.search/1` and the
  `search_tools` meta-tool so both report the same shape.
  """
  def arg_names(%{"properties" => properties} = schema) when is_map(properties) do
    required = schema["required"] || []

    properties
    |> Map.keys()
    |> Enum.sort()
    |> Enum.map(fn name -> if name in required, do: name, else: name <> "?" end)
  end

  def arg_names(_schema), do: []

  # ── module builders ──────────────────────────────────────────────────

  defp create_module(mod, tools, name_fun, dispatcher) do
    funs =
      tools
      |> filter_valid_names(name_fun)
      |> Enum.map(&tool_fun(&1, name_fun, dispatcher))

    body = quote do: (unquote_splicing(funs))
    Module.create(mod, body, Macro.Env.location(__ENV__))
    mod
  end

  defp create_root(root, first_party, upstream, all_tools, dispatcher) do
    raw_name = fn tool -> tool["name"] end

    first_party_funs =
      first_party
      |> filter_valid_names(raw_name)
      |> Enum.map(&tool_fun(&1, raw_name, dispatcher))

    # Flat raw-name defs for upstream tools too (e.g. `github__get_issue`) —
    # this is what the system prompt/search_tools/read_tool actually teach
    # models to call; the per-prefix submodules remain as sugar.
    upstream_funs =
      upstream
      |> filter_valid_names(raw_name)
      |> Enum.map(&tool_fun(&1, raw_name, dispatcher))

    helpers = root_helpers(all_tools, dispatcher)
    body = quote do: (unquote_splicing(first_party_funs ++ upstream_funs ++ helpers))
    Module.create(root, body, Macro.Env.location(__ENV__))
    root
  end

  # Skip (rather than crash on) any tool whose raw name isn't a valid Elixir
  # function identifier — logging so the gap is visible without taking down
  # generation for every other tool.
  defp filter_valid_names(tools, name_fun) do
    Enum.filter(tools, fn tool ->
      name = name_fun.(tool)

      if is_binary(name) and Regex.match?(@valid_fun_name, name) do
        true
      else
        Logger.warning(
          "[code_exec] skipping generated function for tool with invalid name: #{inspect(name)}"
        )

        false
      end
    end)
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
        schema = t["inputSchema"] || %{}

        %{
          name: t["name"],
          description: t["description"] || "",
          schema: schema,
          args: arg_names(schema)
        }
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
        @doc ~s(All tools as %{"name" => ..., "description" => ...} maps.)
        def list do
          Enum.map(unquote(Macro.escape(index)), fn t ->
            %{"name" => t.name, "description" => t.description}
          end)
        end
      end,
      quote do
        @doc ~s"""
        Ranked keyword search over tool names + descriptions (case-insensitive), \
        best match first — see `OrcaHub.MCP.CodeExec.ToolSearch` for the ranking \
        details. Returns %{"name" =>, "description" =>, "args" =>} maps, where \
        "args" lists the tool's argument names (optional ones suffixed "?").
        """
        def search(query) when is_binary(query) do
          unquote(Macro.escape(index))
          |> unquote(ToolSearch).search(query)
          |> Enum.map(fn t ->
            %{"name" => t.name, "description" => t.description, "args" => t.args}
          end)
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
