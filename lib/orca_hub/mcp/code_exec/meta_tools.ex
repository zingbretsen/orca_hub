defmodule OrcaHub.MCP.CodeExec.MetaTools do
  @moduledoc """
  The collapsed MCP tool surface presented to a code-exec session.

  When `code_exec` is enabled for a connection, `tools/list` returns ONLY these
  three meta-tools instead of flattening every first-party and upstream tool:

    * `run_elixir`   — evaluate model-authored Elixir that calls tools as named
      `Tools.*` functions and stitches results with stdlib (the main surface)
    * `search_tools` — read-only ranked keyword search over the live registry
    * `read_tool`    — read-only fetch of a tool's description + input schema

  First-party AND upstream tools are still reachable — but only as `Tools.*`
  functions inside `run_elixir` (and discoverable there via `Tools.search/1` /
  `Tools.schema/1`). `search_tools` / `read_tool` exist so the model can explore
  the registry cheaply before writing code.

  `run_elixir`'s result text distinguishes **rejected before running** (syntax
  error / allowlist violation — the model should fix its code) from **ran and
  failed** (`Tools.Error`, another exception, or a timeout — a tool/expression
  outcome).

  Variables assigned in `run_elixir` persist across calls within the same
  session (see `OrcaHub.MCP.CodeExec.BindingStore`) — only a successful eval
  updates the stored binding, and `"reset": true` clears it.
  """

  alias OrcaHub.MCP.CodeExec
  alias OrcaHub.MCP.CodeExec.{ToolGen, ToolSearch}
  alias OrcaHub.MCP.Tools.Result

  @run_elixir_tool %{
    "name" => "run_elixir",
    "description" => """
    Evaluate Elixir code that can call OrcaHub + upstream MCP tools as named \
    functions and combine their results with the standard library. Prefer this \
    over many separate tool calls: write one snippet that calls several tools \
    and returns only the slim value you need.

    Tools are exposed as `Tools.*` functions that AUTO-UNWRAP the result and \
    RAISE `Tools.Error` on failure, so they compose with `|>` and `Enum`:

        Tools.github__list_issues(%{"repo" => "o/r"})
        |> Enum.filter(& &1["state"] == "open")
        |> Enum.map(& &1["title"])

    Discover tools from inside code with `Tools.search("query")`, \
    `Tools.list()`, and `Tools.schema("name")`. `search`/`list` return maps \
    with "name"/"description" keys (search results also include "args" — a \
    list of argument names, with optional ones suffixed "?", e.g. \
    ["repo", "number?"]); `schema` returns a map. For explicit error handling \
    use `Tools.try_call("name", args)` -> `{:ok, value} | {:error, reason}`, or \
    `Tools.call("name", args)` for the faithful MCP envelope. Pure stdlib \
    (Enum, Map, String, Jason, ...) is available; OrcaHub internals, File, \
    System, and process/dispatch primitives are blocked. The returned value of \
    the last expression and any stdout are sent back — keep it slim: \
    filter/project before returning.

    Variables you bind PERSIST across run_elixir calls within this session, \
    like a REPL: fetch data once into a variable, then slice/reshape it in \
    later calls instead of re-fetching.

        sessions = Tools.search_sessions(%{"status" => "error"})
        # ...next call...
        Enum.map(sessions, & &1["title"])

    Pass `"reset": true` to clear your session's stored variables and start \
    fresh (the snippet then runs against an empty binding).\
    """,
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{
        "code" => %{"type" => "string", "description" => "Elixir code to evaluate."},
        "reset" => %{
          "type" => "boolean",
          "description" =>
            "If true, clear this session's persisted variables before evaluating " <>
              "(the snippet then runs with a fresh binding)."
        }
      },
      "required" => ["code"]
    }
  }

  @search_tools_tool %{
    "name" => "search_tools",
    "description" =>
      "Ranked keyword search over the available tool registry (first-party + " <>
        "upstream) — matched against tool names and descriptions, best match " <>
        "first (case-insensitive). Returns matching tools as " <>
        "{\"name\", \"description\", \"args\"} maps, where \"args\" lists argument " <>
        "names (optional ones suffixed \"?\"). These tools are callable as " <>
        "Tools.<name>/1 inside run_elixir.",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{
        "query" => %{"type" => "string", "description" => "Case-insensitive search query."}
      },
      "required" => ["query"]
    }
  }

  @read_tool_tool %{
    "name" => "read_tool",
    "description" =>
      "Fetch a single tool's description and JSON input schema by its raw MCP " <>
        "name (e.g. \"github__get_issue\"). Use to learn a tool's arguments " <>
        "before calling it as Tools.<name>/1 inside run_elixir.",
    "inputSchema" => %{
      "type" => "object",
      "properties" => %{
        "name" => %{"type" => "string", "description" => "Raw MCP tool name."}
      },
      "required" => ["name"]
    }
  }

  @tools [@run_elixir_tool, @search_tools_tool, @read_tool_tool]

  @doc "The collapsed meta-tool definitions shown to a code-exec connection."
  def list, do: @tools

  @doc "True if `name` is one of the meta-tools."
  def meta_tool?(name), do: Enum.any?(@tools, &(&1["name"] == name))

  @doc """
  Dispatch a meta-tool call. `state` is the MCP server state, threaded into
  evaluated code so `Tools.*` calls run with the connection's identity.
  """
  def call("run_elixir", args, state), do: run_elixir(args, state)
  def call("search_tools", args, _state), do: search_tools(args["query"])
  def call("read_tool", args, _state), do: read_tool(args["name"])

  def call(name, _args, _state) do
    Result.error(
      "Unknown tool: #{name}. In code-exec mode this connection exposes only " <>
        "run_elixir, search_tools, and read_tool; call other tools as Tools.<name> " <>
        "inside run_elixir."
    )
  end

  # ── run_elixir ───────────────────────────────────────────────────────

  defp run_elixir(%{"code" => code} = args, state) when is_binary(code) do
    reset? = args["reset"] == true

    case CodeExec.run(code, state, reset: reset?) do
      {:ok, %{value: value, stdout: stdout} = result} ->
        Result.text(format_success(value, stdout, Map.get(result, :note)))

      {:error, {:rejected, reason}} ->
        Result.error("Code rejected before running (fix your code): #{reason}")

      {:error, {:timeout, ms}} ->
        Result.error("Code ran but was killed after exceeding the #{ms}ms time limit.")

      {:error, {:exception, %{banner: banner, line: line, stdout: stdout}}} ->
        Result.error(format_exception(banner, line, stdout))
    end
  end

  defp run_elixir(_args, _state),
    do: Result.error("run_elixir requires a `code` string argument.")

  # Same budget the sandbox caps stdout/exception banners at (see Sandbox's
  # @default_max_output) — the returned value gets no cap otherwise, and a big
  # tool result would be a context bomb.
  @max_value_bytes 50_000

  defp format_success(value, stdout, note) do
    out = if stdout == "", do: "", else: "stdout:\n#{stdout}\n"
    note_line = if note, do: "\n\n#{note}", else: ""
    "#{out}=> #{cap_value(inspect(value, pretty: true, limit: :infinity))}#{note_line}"
  end

  defp cap_value(formatted) when byte_size(formatted) > @max_value_bytes do
    truncated = byte_size(formatted) - @max_value_bytes

    binary_part(formatted, 0, @max_value_bytes) <>
      "\n…[truncated #{truncated} bytes — filter/project the value in your code before returning it]"
  end

  defp cap_value(formatted), do: formatted

  defp format_exception(banner, line, stdout) do
    where = if line, do: " (at line #{line})", else: ""
    out = if stdout == "", do: "", else: "stdout before failure:\n#{stdout}\n"
    "#{out}Code ran but raised#{where}:\n#{banner}"
  end

  # ── search_tools / read_tool (read-only over the live registry) ──────

  defp search_tools(nil), do: Result.error("search_tools requires a `query` string argument.")

  defp search_tools(query) when is_binary(query) do
    matches =
      ToolGen.live_tools()
      |> Enum.map(fn t -> %{name: t["name"], description: t["description"] || "", raw: t} end)
      |> ToolSearch.search(query)
      |> Enum.map(fn %{raw: t} ->
        %{
          "name" => t["name"],
          "description" => t["description"] || "",
          "args" => ToolGen.arg_names(t["inputSchema"] || %{})
        }
      end)

    Result.text(Jason.encode!(%{"count" => length(matches), "tools" => matches}))
  end

  defp read_tool(nil), do: Result.error("read_tool requires a `name` string argument.")

  defp read_tool(name) when is_binary(name) do
    case Enum.find(ToolGen.live_tools(), &(&1["name"] == name)) do
      nil ->
        Result.error("Unknown tool: #{name}. Use search_tools to discover available tools.")

      tool ->
        Result.text(
          Jason.encode!(%{
            "name" => tool["name"],
            "description" => tool["description"] || "",
            "inputSchema" => tool["inputSchema"] || %{}
          })
        )
    end
  end
end
