defmodule OrcaHub.MCP.CodeExec.MetaTools do
  @moduledoc """
  The collapsed MCP tool surface presented to a code-exec session.

  When `code_exec` is enabled for a connection, `tools/list` returns a handful
  of tools instead of flattening every first-party and upstream tool:

    * `run_elixir`   — evaluate model-authored Elixir that calls tools as named
      `Tools.*` functions and stitches results with stdlib (the main surface)
    * `search_tools` — read-only ranked keyword search over the live registry
    * `send_message_to_session`, `get_session_tail` — **passthroughs** to the
      real first-party tools of the same name (`OrcaHub.MCP.Tools.Sessions`).
      They're promoted to standalone tools because orchestrator/code-exec
      sessions call them so frequently that round-tripping through
      `run_elixir` for every call was pure overhead. Their definitions are
      sourced from `OrcaHub.MCP.Tools.list/0` (not hand-duplicated), and
      `call/3` delegates straight to `OrcaHub.MCP.Tools.call/3` — no
      reimplementation here.

  Every OTHER first-party AND upstream tool is still reachable — but only as
  `Tools.*` functions inside `run_elixir` (and discoverable there via
  `Tools.search/1` / `Tools.schema/1`). `search_tools` exists so the model can
  explore the registry cheaply before writing code.

  A third meta-tool, `read_tool` (single-tool schema lookup by raw MCP name),
  was removed: production usage showed it was the weakest of the three (27
  calls across 15 sessions vs. 589 across 70 for `run_elixir`) and its job is
  fully covered by `Tools.schema/1` inside `run_elixir`. Old sessions may still
  have persisted `read_tool` calls in their message history — `MessageComponents`
  keeps a render clause for those — but it's no longer callable.

  Tool definitions are built **at call time**, not a compile-time `@tools`
  attribute, so `run_elixir`'s description can list the CURRENT first-party
  tool names (`OrcaHub.MCP.Tools.list/0`) and connected upstream server
  prefixes (`OrcaHub.MCP.UpstreamClient.prefixes/0`) — both of which change at
  runtime — without risking the list drifting from a hand-maintained literal.

  `run_elixir`'s result text distinguishes **rejected before running** (syntax
  error / allowlist violation — the model should fix its code) from **ran and
  failed** (`Tools.Error`, another exception, or a timeout — a tool/expression
  outcome).

  Variables assigned in `run_elixir` persist across calls within the same
  session (see `OrcaHub.MCP.CodeExec.BindingStore`). A raise still persists
  whatever earlier top-level statements in the snippet successfully bound
  (see `OrcaHub.MCP.CodeExec.Sandbox`'s sequential top-level evaluation);
  `"reset": true` clears the stored binding entirely.
  """

  alias OrcaHub.MCP.CodeExec
  alias OrcaHub.MCP.CodeExec.{ToolGen, ToolSearch}
  alias OrcaHub.MCP.Tools.Result
  alias OrcaHub.MCP.UpstreamClient

  @meta_tool_names ~w(run_elixir search_tools)
  @passthrough_tool_names ~w(send_message_to_session get_session_tail)

  @doc "The collapsed tool definitions shown to a code-exec connection: the meta-tools plus any passthrough tools."
  def list, do: [run_elixir_tool(), search_tools_tool() | passthrough_tool_definitions()]

  @doc "True if `name` is one of the meta-tools (run_elixir/search_tools — not a passthrough tool)."
  def meta_tool?(name), do: name in @meta_tool_names

  @doc "The first-party tool names promoted to standalone top-level tools in code-exec mode."
  def passthrough_tool_names, do: @passthrough_tool_names

  @doc """
  Dispatch a meta-tool or passthrough-tool call. `state` is the MCP server
  state, threaded into evaluated code so `Tools.*` calls run with the
  connection's identity (and passed straight through to the delegated
  first-party call for passthrough tools).
  """
  def call("run_elixir", args, state), do: run_elixir(args, state)
  def call("search_tools", args, _state), do: search_tools(args["query"])

  def call(name, args, state) when name in @passthrough_tool_names do
    OrcaHub.MCP.Tools.call(name, args, state)
  end

  def call(name, _args, _state) do
    exposed_names = Enum.join(@meta_tool_names ++ @passthrough_tool_names, ", ")

    Result.error(
      "Unknown tool: #{name}. In code-exec mode this connection exposes only " <>
        "#{exposed_names}; call other tools as Tools.<name> inside run_elixir " <>
        "(use Tools.schema(\"name\") there for a tool's input schema)."
    )
  end

  # ── tool definitions (built at call time — see moduledoc) ────────────

  defp run_elixir_tool do
    %{
      "name" => "run_elixir",
      "description" => run_elixir_description(),
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
  end

  defp run_elixir_description do
    """
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
    `Tools.list()`, and `Tools.schema("name")` — the tool's JSON input schema, \
    worth checking before calling an unfamiliar tool. `search`/`list` return \
    maps with "name"/"description" keys (search results also include "args" — \
    a list of argument names, with optional ones suffixed "?", e.g. \
    ["repo", "number?"]); `schema` returns a map (or `nil`). For explicit error \
    handling use `Tools.try_call("name", args)` -> `{:ok, value} | {:error, reason}`, \
    or `Tools.call("name", args)` for the faithful MCP envelope. Pure stdlib \
    (Enum, Map, String, Jason, ...) is available; OrcaHub internals, File, \
    System, and process/dispatch primitives are blocked. The returned value of \
    the last expression and any stdout are sent back — keep it slim: \
    filter/project before returning.

    First-party OrcaHub tools available as Tools.* in every session: \
    #{first_party_tool_names()}. #{upstream_prefixes_line()}

    Variables you bind PERSIST across run_elixir calls within this session, \
    like a REPL: fetch data once into a variable, then slice/reshape it in \
    later calls instead of re-fetching.

        sessions = Tools.search_sessions(%{"status" => "error"})
        # ...next call...
        Enum.map(sessions, & &1["title"])

    Pass `"reset": true` to clear your session's stored variables and start \
    fresh (the snippet then runs against an empty binding).\
    """
  end

  defp first_party_tool_names do
    OrcaHub.MCP.Tools.list()
    |> Enum.map(& &1["name"])
    |> Enum.sort()
    |> Enum.join(", ")
  end

  defp upstream_prefixes_line do
    case UpstreamClient.prefixes() do
      [] ->
        "No upstream MCP servers are currently connected."

      prefixes ->
        "Connected upstream MCP servers: #{Enum.join(Enum.sort(prefixes), ", ")} — their " <>
          "tools are namespaced <prefix>__<tool> and searchable via search_tools / Tools.search."
    end
  end

  # Passthrough tools are standalone in code-exec mode but must not drift from
  # the real first-party schema — so their definitions are looked up by name
  # in the live registry rather than duplicated here.
  defp passthrough_tool_definitions do
    OrcaHub.MCP.Tools.list()
    |> Enum.filter(&(&1["name"] in @passthrough_tool_names))
  end

  defp search_tools_tool do
    %{
      "name" => "search_tools",
      "description" =>
        "Ranked keyword search over the available tool registry (first-party + " <>
          "upstream) — matched against tool names and descriptions, best match " <>
          "first (case-insensitive). Returns matching tools as " <>
          "{\"name\", \"description\", \"args\"} maps, where \"args\" lists argument " <>
          "names (optional ones suffixed \"?\"). These tools are callable as " <>
          "Tools.<name>/1 inside run_elixir — use Tools.schema/1 there for a tool's " <>
          "full input schema.",
      "inputSchema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{"type" => "string", "description" => "Case-insensitive search query."}
        },
        "required" => ["query"]
      }
    }
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

      {:error, {:exception, %{banner: banner, line: line, stdout: stdout} = info}} ->
        Result.error(format_exception(banner, line, stdout, Map.get(info, :note)))
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

  defp format_exception(banner, line, stdout, note) do
    where = if line, do: " (at line #{line})", else: ""
    out = if stdout == "", do: "", else: "stdout before failure:\n#{stdout}\n"
    note_line = if note, do: "\n\n#{note}", else: ""
    "#{out}Code ran but raised#{where}:\n#{banner}#{note_line}"
  end

  # ── search_tools (read-only over the live registry) ───────────────────

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
end
