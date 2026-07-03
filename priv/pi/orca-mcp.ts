/**
 * OrcaHub's pi <-> MCP bridge extension (backend_abstraction_spec.md §12.5).
 *
 * pi has no built-in MCP client — a pi session otherwise can't reach
 * OrcaHub's own MCP servers (the first-party "orca" tools:
 * send_message_to_session, start_session, search_sessions, …; any
 * project/session-scoped upstream server; the run_elixir/search_tools/
 * read_tool code-exec meta-tools). This extension bridges that gap by
 * speaking the hub's `/mcp` Streamable HTTP JSON-RPC transport itself
 * (hand-rolled over `fetch` — Node 18+ global, no npm dependency added) and
 * re-exposing every discovered tool via `pi.registerTool`.
 *
 * ## Config: ORCA_MCP_URL
 *
 * `Backend.Pi.spawn_spec/2` (lib/orca_hub/backend/pi.ex) injects
 * `ORCA_MCP_URL` into the spawned process's env — the SAME URL
 * `Backend.Claude` bakes into its inline `--mcp-config` JSON, built by the
 * ONE shared `OrcaHub.Backend.McpUrl.orca_url/1` helper, so the two backends
 * can never bake different `orca_session_id`/`orchestrator`/`code_exec`
 * query params. Whatever tool set the hub's `/mcp` endpoint would show
 * Claude for this session (full orchestrator set, the restricted regular-
 * session set, or the collapsed code-exec meta-tools — see
 * `OrcaHub.MCP.Server`/`OrcaHub.MCP.Tools`) is exactly what a pi session
 * sees too, because both backends hit the identical URL.
 *
 * Per-session orchestrator/code_exec flag CHANGES mid-session need no extra
 * handling here: `SessionRunner`'s warm-port eviction
 * (`apply_flag_change_no_turn`/`apply_flag_change_running` in
 * session_runner.ex) is backend-agnostic — it force-closes the warm pi
 * process on a flag change so the NEXT turn cold-reopens via `spawn_spec/2`,
 * which re-bakes `ORCA_MCP_URL` from the new flag values and re-loads this
 * extension from scratch, re-running the handshake below against the
 * updated URL. No pi-specific eviction code was needed.
 *
 * ## Degrade silently
 *
 * `ORCA_MCP_URL` absent, or the endpoint unreachable/erroring at any step of
 * the handshake below, must NEVER break the pi session — it just means zero
 * orca tools get registered. Logged at most once via `console.error`
 * (stderr — `--mode rpc`'s stdout is the NDJSON RPC channel itself;
 * `console.log`/stdout output here would corrupt that stream, so this
 * extension never writes to stdout).
 *
 * ## Tool naming: mcp__orca__<raw_name>
 *
 * Claude's `--mcp-config` points ONE `mcpServers` entry, keyed `"orca"`, at
 * this same `/mcp` endpoint (`Backend.Claude.mcp_config_json/1`) — the
 * Claude CLI then names every tool that endpoint returns
 * `mcp__orca__<raw_name>` (its own client-side MCP naming convention: `mcp__
 * <config-key>__<tool-name>`). `OrcaHub.MCP.Server`'s `tools/list` already
 * returns upstream-server tools PRE-prefixed with their own server prefix
 * (`OrcaHub.MCP.UpstreamClient`: `"#{conn.prefix}__#{tool["name"]}"`), so
 * from Claude's perspective an upstream tool ends up double-prefixed, e.g.
 * `mcp__orca__github__get_issue`. This extension mirrors that exactly:
 * every tool this endpoint returns is registered as `mcp__orca__<raw_name>`,
 * with no other transformation — matching `MessageComponents`' existing
 * `mcp__orca__run_elixir`/`search_tools`/`read_tool` pattern matches
 * (message_components.ex ~736-763) and its generic `mcp__*` fallback
 * renderer for everything else, byte for byte. `Backend.Pi.normalize/2`'s
 * `translate_tool/2` passes unrecognized tool names through unchanged, so a
 * toolCall named `mcp__orca__send_message_to_session` reaches
 * `MessageComponents` completely unmodified — zero rendering changes needed
 * anywhere in the Elixir/LiveView layer.
 */

const REQUEST_TIMEOUT_MS = 15_000;
const MCP_SERVER_KEY = "orca";
const PROTOCOL_VERSION = "2025-03-26";

type McpToolDef = {
  name: string;
  description?: string;
  inputSchema?: Record<string, unknown>;
};

type McpContentBlock = { type: string; text?: string };

type McpToolCallResult = {
  content?: McpContentBlock[];
  isError?: boolean;
};

// A tiny hand-rolled MCP Streamable HTTP JSON-RPC client — no SDK, no npm
// dependency. The hub's own transport (lib/orca_hub/mcp/plug.ex) always
// answers a POST with a single `application/json` body (never SSE), but
// `parseRpcBody` defensively also understands an SSE-framed `data: {...}`
// line in case a FUTURE upstream server this bridges to answers that way
// (OrcaHub.MCP.UpstreamClient.parse_body/1 has the identical fallback,
// server-side, for the same reason).
function createMcpClient(url: string) {
  let sessionId: string | undefined;
  let nextId = 1;

  async function post(
    body: Record<string, unknown>,
    signal: AbortSignal | undefined,
  ): Promise<{ status: number; text: string; headers: Headers }> {
    const timeoutController = new AbortController();
    const timeout = setTimeout(() => timeoutController.abort(), REQUEST_TIMEOUT_MS);
    const combined = combineSignals(signal, timeoutController.signal);

    const headers: Record<string, string> = {
      "content-type": "application/json",
      accept: "application/json, text/event-stream",
    };
    if (sessionId) headers["mcp-session-id"] = sessionId;

    try {
      const resp = await fetch(url, {
        method: "POST",
        headers,
        body: JSON.stringify(body),
        signal: combined,
      });

      const respSessionId = resp.headers.get("mcp-session-id");
      if (respSessionId) sessionId = respSessionId;

      const text = await resp.text();
      return { status: resp.status, text, headers: resp.headers };
    } finally {
      clearTimeout(timeout);
    }
  }

  function parseRpcBody(text: string, contentType: string): any {
    if (!text) return undefined;

    if (contentType.includes("text/event-stream")) {
      for (const line of text.split("\n")) {
        const trimmed = line.trim();
        if (trimmed.startsWith("data:")) {
          try {
            return JSON.parse(trimmed.slice(5).trim());
          } catch {
            // fall through to the raw-JSON attempt below
          }
        }
      }
    }

    try {
      return JSON.parse(text);
    } catch {
      return undefined;
    }
  }

  async function request(
    method: string,
    params: unknown,
    signal: AbortSignal | undefined,
  ): Promise<any> {
    const id = nextId++;
    const { status, text, headers } = await post({ jsonrpc: "2.0", id, method, params }, signal);

    if (status < 200 || status >= 300) {
      throw new Error(`orca MCP ${method}: HTTP ${status}`);
    }

    const payload = parseRpcBody(text, headers.get("content-type") || "");
    if (!payload) {
      throw new Error(`orca MCP ${method}: empty/unparseable response body`);
    }
    if (payload.error) {
      throw new Error(`orca MCP ${method}: ${payload.error.message || JSON.stringify(payload.error)}`);
    }
    return payload.result;
  }

  async function notify(method: string, params?: unknown): Promise<void> {
    await post({ jsonrpc: "2.0", method, params }, undefined);
  }

  return {
    async initialize(): Promise<void> {
      await request(
        "initialize",
        {
          protocolVersion: PROTOCOL_VERSION,
          capabilities: {},
          clientInfo: { name: "orca-pi-bridge", version: "0.1.0" },
        },
        undefined,
      );
      await notify("notifications/initialized");
    },

    async listTools(): Promise<McpToolDef[]> {
      const result = await request("tools/list", undefined, undefined);
      return Array.isArray(result?.tools) ? (result.tools as McpToolDef[]) : [];
    },

    async callTool(
      name: string,
      args: unknown,
      signal: AbortSignal | undefined,
    ): Promise<McpToolCallResult> {
      return (await request("tools/call", { name, arguments: args ?? {} }, signal)) as McpToolCallResult;
    },
  };
}

// Ties two AbortSignals into one that fires when EITHER fires — used to
// thread a tool call's own AbortSignal (so an OrcaHub "stop" click aborts an
// in-flight tools/call fetch immediately) together with this bridge's own
// request timeout. Same lesson as priv/pi/orca.ts's `question` tool: a
// blocking call that ignores the handler's own `signal` leaves the turn
// unable to end on abort.
function combineSignals(a: AbortSignal | undefined, b: AbortSignal): AbortSignal {
  if (!a) return b;
  if (a.aborted) return a;
  if (b.aborted) return b;

  const controller = new AbortController();
  const onAbort = () => controller.abort();
  a.addEventListener("abort", onAbort, { once: true });
  b.addEventListener("abort", onAbort, { once: true });
  return controller.signal;
}

function toolResultText(result: McpToolCallResult): string {
  const blocks = result.content ?? [];
  const text = blocks
    .filter((b) => b.type === "text" && typeof b.text === "string")
    .map((b) => b.text as string)
    .join("\n");

  if (text) return text;
  return result.isError ? "Tool call failed with no error message." : "";
}

// Raw JSON Schema (an MCP tool's `inputSchema`) isn't directly a TypeBox
// schema — TypeBox's runtime validator dispatches on a `[Kind]` symbol that
// plain JSON Schema objects don't carry. `Type.Unsafe(schema)` is TypeBox's
// documented escape hatch for exactly this (pi's own dependency,
// `@earendil-works/pi-ai`'s `StringEnum` helper, uses the identical
// `Type.Unsafe({...raw JSON schema...})` pattern to inject a hand-built
// schema object) — it treats the given object as the schema verbatim,
// bypassing TypeBox's own type-safe builders.
function toolParameters(TypeUnsafe: (schema: unknown) => unknown, inputSchema: unknown) {
  if (inputSchema && typeof inputSchema === "object") return TypeUnsafe(inputSchema);
  return TypeUnsafe({ type: "object", properties: {} });
}

export default async function orcaMcp(pi: any) {
  const { Type } = await import("typebox");

  let loggedOnce = false;
  const logOnce = (message: string) => {
    if (loggedOnce) return;
    loggedOnce = true;
    // stderr only — see moduledoc above on why stdout is off-limits here.
    console.error(`[orca-mcp] ${message}`);
  };

  pi.on("session_start", async () => {
    const url = process.env.ORCA_MCP_URL;
    if (!url) {
      logOnce("ORCA_MCP_URL not set — no orca MCP tools registered");
      return;
    }

    let tools: McpToolDef[];
    const client = createMcpClient(url);

    try {
      await client.initialize();
      tools = await client.listTools();
    } catch (err) {
      logOnce(`failed to bridge orca MCP tools from ${url}: ${(err as Error).message}`);
      return;
    }

    if (tools.length === 0) {
      logOnce(`connected to ${url} but tools/list returned 0 tools`);
      return;
    }

    for (const tool of tools) {
      const registeredName = `mcp__${MCP_SERVER_KEY}__${tool.name}`;

      pi.registerTool({
        name: registeredName,
        label: tool.name,
        description: tool.description || tool.name,
        parameters: toolParameters(Type.Unsafe, tool.inputSchema),

        async execute(_toolCallId: string, params: unknown, signal: AbortSignal | undefined) {
          let result: McpToolCallResult;
          try {
            result = await client.callTool(tool.name, params, signal);
          } catch (err) {
            // Network/timeout/HTTP failure calling the hub — same posture as
            // an MCP isError:true result: throw so pi marks the tool result
            // isError:true and reports it to the model.
            throw new Error(`orca MCP tools/call ${tool.name} failed: ${(err as Error).message}`);
          }

          const text = toolResultText(result);

          // docs/extensions.md: "throw to signal an error... Returning a
          // value never sets the error flag." Mirrors the hub's own
          // isError:true content (OrcaHub.MCP.Tools.Result.error/1) onto
          // pi's error convention.
          if (result.isError) {
            throw new Error(text || `${tool.name} failed`);
          }

          return {
            content: [{ type: "text", text }],
            details: {},
          };
        },
      });
    }
  });
}
