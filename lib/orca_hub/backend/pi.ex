defmodule OrcaHub.Backend.Pi do
  @moduledoc """
  `OrcaHub.Backend` implementation for Mario Zechner's `pi` coding agent
  (npm `@earendil-works/pi-coding-agent`, bin `pi`), over `pi --mode rpc` —
  a long-lived, bidirectional JSONL-over-stdio protocol (spec §12.2).

  ## Verified against 0.80.3 (live capture, superseding the docs-only §12.2
  research pass)

  The host had `pi` 0.75.3 at implementation start; it was upgraded to
  0.80.3 mid-implementation (both the installed package and its bundled
  `docs/rpc.md` moved together). Every wire-protocol claim below was
  re-captured live against the 0.80.3 binary (a Python stdio harness driving
  `pi --mode rpc` and `pi -p --mode json`, real Fireworks-provider turns via
  `~/.pi/agent/auth.json`) — 0.75.3 was never shipped in this adapter.
  Deviations from the original §12.2 research draft:

    * **No handshake, no FSM.** §12.2 speculated an `initialize`/session-ready
      exchange might gate the first `prompt`. Live-verified: `pi --mode rpc`
      accepts `{"type":"prompt",...}` as the very first stdin write — no
      handshake, no `pending_prompt` stash. `on_open/1` still writes one
      command (`get_state`), but purely to *learn* the session id, not to
      gate anything; it and the user's first `prompt` are written
      back-to-back and pi processes/responds to both in order.
    * **Session id capture differs by mode.** Streaming (`--mode rpc`) never
      unprompted-announces a session id on stdout — `on_open/1` sends
      `{"type":"get_state"}` and `session_id/1` reads
      `response.data.sessionId` from the reply. One-shot (`-p --mode json`)
      DOES announce it unprompted: the very first stdout line is
      `{"type":"session","id":…,…}`. `normalize/2` handles both shapes.
    * **`--session-id <uuid>` (not `--session <path|id>`) is the resume
      flag to use.** 0.80.3 added `--session-id <id>` ("use exact project
      session id, creating it if missing") alongside the pre-existing
      `--session <path|id>` (which 404s — "No session found matching …" —
      if the id isn't already on disk in that `--session-dir`). Live-verified
      round-trip: spawn with `--session-id <uuid>` (fresh), later spawn again
      with the SAME `--session-id` + `--session-dir` → full prior context
      recalled. This adapter always passes `--session-id` when resuming,
      never `--session`.
    * **Everything else in §12.2 matched 0.80.3 exactly**: framing (strict
      JSONL, no `"jsonrpc"` field, commands optionally carry `id`, responses
      echo it), `{"type":"prompt","message":…}` / `{"type":"abort"}` framing,
      the `message_end`/`tool_execution_end`/`agent_end` event vocabulary,
      built-in tool names (`bash`/`read`/`write`/`edit`/`grep`/`find`/`ls`),
      the `extension_ui_request`/`extension_ui_response` sub-protocol shape,
      and `--append-system-prompt`. `agent_end.messages` additionally carries
      a harmless `willRetry` field and per-message `usage` gained a
      `cacheWrite1h` field — both ignored here.

  ## "pi backend groundwork" slice (extension-UI reply loop, orca.ts, session stats)

  Three additions on top of the Phase 4 adapter above, all still pi-only:

    * **Extension-UI reply loop.** `handle_peer_request/2` stashes a
      mid-turn `select`/`confirm`/`input`/`editor` dialog request
      (`extension_ui_request`) as a NEW `pi_ui_request` event (spec §3.3 —
      a custom type, same posture as the pre-existing `cli_error` type,
      rather than force-fitting Claude's AskUserQuestion tool_use/tool_result
      shape onto a fundamentally different wire mechanism) and tracks the
      pending request (`id` + `method` only) in `backend_state`. The answer
      travels back through `SessionRunner.answer_ui_request/3` (allowed
      mid-turn — the dialog blocks the CURRENT turn) →
      `Backend.encode_ui_response/4` → `encode_ui_response/3` below, which
      validates the id against the SAME pending-request bookkeeping and
      writes `extension_ui_response` directly to the port. Keyed purely on
      `id` — never coupled to "a tool_use is in flight" — so a FUTURE
      extension (e.g. plan-mode, popping a dialog after `agent_end` with no
      tool call at all) flows through the identical loop with no new runner
      code.
    * **`priv/pi/orca.ts`** — loaded via `-e <path>` in `spawn_spec/2`
      (`Application.app_dir/2`-resolved, so it also works from an OTP
      release). Registers a `question` tool mirroring Claude's
      AskUserQuestion as closely as pi's RPC dialog primitives allow:
      `ctx.ui.select` for multiple-choice, `ctx.ui.input` for free-form
      (pi's `ctx.ui.custom()` returns `undefined` in RPC mode, so it's
      unusable here), both with a 10-minute dialog timeout so an unanswered
      question auto-resolves instead of hanging the turn — pi's own timeout
      machinery handles that (docs/rpc.md), not Elixir-side bookkeeping.
    * **Session stats.** `get_session_stats` is queued (via
      `backend_state.pending_writes`) every time `agent_end` fires, and its
      response is normalized into a `pi_session_stats` event
      (`tokens`/`cost`/`context_usage`, verbatim field names from pi's
      response). Surfaced through a NEW `Capabilities.session_stats` flag
      (`false` by default, `true` here) — deliberately NOT reusing `usage`,
      which gates the Claude-API OAuth quota panel (`OrcaHub.Claude.Usage`),
      the wrong data source for a non-Claude backend.

  ## Design (mirrors `Backend.Codex`'s structure, simpler FSM)

  Unlike Codex (mandatory `initialize`→`initialized`→`thread/start` handshake
  before any turn can start, tracked via `backend_state.phase` +
  `pending_requests` + `pending_prompt`), pi needs none of that: every
  callback here is close to stateless. `backend_state` holds `:agent_start_ms`
  (wall-clock start of the in-flight agent run, stashed on `agent_start` and
  read back at `agent_end` to synthesize `duration_ms` — pi's own protocol
  has no elapsed-time field) plus, as of the "pi backend groundwork" slice
  below, `:pending_ui_request` (the currently-blocked extension-UI dialog, if
  any) and a one-shot `:pending_writes` entry queued at `agent_end` to
  request session stats.

  `normalize/2` treats `message_end{role:"assistant"}` as the sole source of
  assistant content (text/thinking/tool_use) and `tool_execution_end` as the
  sole source of tool results — `turn_end` and `agent_end.messages` embed the
  SAME content redundantly (useful for `agent_end`'s result-synthesis pass:
  scanning its own bundled `messages` for the last assistant's `stopReason`
  and summed `usage`/`cost`, without extra `backend_state` bookkeeping), so
  emitting from `turn_end`/`agent_end` too would duplicate every message in
  the feed. `message_update` (streaming deltas) and `tool_execution_start`/
  `tool_execution_update` are dropped per spec Q7 (v1 renders on
  completion only).
  """

  @behaviour OrcaHub.Backend

  require Logger

  alias OrcaHub.Backend.SharedPrompts
  alias OrcaHub.HubRPC

  # Extension UI methods that block waiting for an `extension_ui_response`
  # (spec's Extension UI Protocol) — everything else (`notify`, `setStatus`,
  # `setWidget`, `setTitle`, `set_editor_text`) is fire-and-forget and must
  # NOT get a reply.
  @dialog_ui_methods ~w(select confirm input editor)

  # ── Capabilities ─────────────────────────────────────────────────────

  @impl true
  def capabilities do
    %OrcaHub.Backend.Capabilities{
      streaming: true,
      interrupt: :protocol,
      # As of the orca-mcp bridge (spec §12.5): `priv/pi/orca-mcp.ts` connects
      # to the SAME `/mcp` endpoint Claude uses (URL baked via
      # `Backend.McpUrl.orca_url/1`, injected as `ORCA_MCP_URL`), discovers
      # its tools via `tools/list`, and registers each one with
      # `pi.registerTool` under the exact `mcp__orca__<tool>` name Claude
      # itself would use — so orca tools (send_message_to_session,
      # search_sessions, run_elixir in code-exec mode, …) are reachable from
      # a pi session, and MessageComponents renders their tool_use/tool_result
      # cards with ZERO pi-specific code (it already pattern-matches on the
      # `mcp__orca__*` name string). This flips the UI's orchestrator/
      # code_exec toggles and the MCP-servers modal back on for this backend
      # (spec §7's `mcp` gating list) — mirrors Claude's per-session flag
      # baking exactly (same evict_warm/cold-reopen mechanism in
      # session_runner.ex rebakes the URL, unconditionally, on every backend).
      mcp: true,
      resume: true,
      # No headless account-quota endpoint; per-turn cost/tokens still flow
      # into the synthesized `result` event from pi's own usage/cost fields
      # (better than Codex here — pi reports cost directly, no Anthropic-style
      # OAuth quota query needed for that part).
      usage: false,
      system_prompt: :flag,
      # No MCP-registration race to work around (no MCP support at all) and
      # no other startup handshake to hide behind a throwaway turn — the very
      # first `prompt` write is safe.
      warmup_turn: false,
      # spec §12.4: OrcaHub's own `priv/pi/orca-plan.ts` extension gives pi a
      # read-only plan mode (write/edit tools disabled, bash restricted to a
      # read-only allowlist) — rides the SAME `@capabilities.plan_mode`-gated
      # header chrome as Claude's built-in EnterPlanMode/ExitPlanMode tool
      # pair, just driven by a different (user-toggled, not model-initiated)
      # mechanism underneath — see `plan_mode_toggle` below.
      plan_mode: true,
      # Unlike Claude (model decides when to enter/exit plan mode; no user
      # affordance exists), pi's plan mode is a user-toggled `/plan` command
      # (spec §12.4) — SessionRunner.toggle_plan_mode/1 sends it via
      # encode_toggle_plan_mode/1 below. Gates the toggle button in the UI.
      plan_mode_toggle: true,
      # "pi backend groundwork" slice: the `question` tool in
      # priv/pi/orca.ts + the extension-UI reply loop
      # (handle_peer_request/2 / encode_ui_response/3) give pi the same
      # user-facing capability as Claude's built-in AskUserQuestion tool —
      # asking an interactive question mid-turn — just via a different wire
      # mechanism. The UI branches on this flag, not on which mechanism is
      # underneath (spec §12.3).
      ask_user_question: true,
      # pi reports live token/cost/context-window stats via `get_session_stats`
      # (spec §12.3) — surfaced through a pi-appropriate stats display, kept
      # deliberately separate from `usage` (the Claude-API quota panel gate).
      session_stats: true,
      # spec §12.6: pi's native `steer` command delivers a mid-turn message
      # in place (after the current tool calls, before the next LLM call)
      # instead of interrupting the running turn — see encode_steer_turn/2.
      steering: true
    }
  end

  # ── Models ───────────────────────────────────────────────────────────
  # pi model ids are passthrough "provider/id" strings (live-verified: a
  # LIVE catalog: unlike Claude/Codex, pi can enumerate exactly the models
  # usable with the credentials on this node (`pi --list-models` prints an
  # aligned table of provider/model rows for AUTHENTICATED providers only).
  # `Backend.models_for/2` wraps this in the node-scoped TTL cache, so the
  # shell-out cost isn't paid per render. Any failure (pi missing, non-zero
  # exit, unparseable output) degrades to [] — the free-text model field
  # still accepts anything.

  @impl true
  def models do
    exe = Application.get_env(:orca_hub, :pi_executable) || System.find_executable("pi")

    with exe when is_binary(exe) <- exe,
         {out, 0} <- System.cmd(exe, ["--list-models"], stderr_to_stdout: true) do
      parse_model_list(out)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  # Parses `pi --list-models` output: a header line
  # (`provider   model   context  max-out  thinking  images`) followed by
  # whitespace-aligned rows. The picker id is pi's combined "provider/model"
  # form (an embedded "/" resolves the provider — no separate --provider
  # flag needed); the label is the model's basename plus provider, since
  # Fireworks ids are long `accounts/fireworks/models/<name>` paths.
  @doc false
  def parse_model_list(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop_while(&String.starts_with?(&1, "provider"))
    |> Enum.flat_map(fn line ->
      case String.split(line, ~r/\s+/, trim: true) do
        [provider, model | _rest] when provider != "provider" ->
          [{"#{provider}/#{model}", "#{Path.basename(model)} (#{provider})"}]

        _ ->
          []
      end
    end)
  end

  # ── Spawn ────────────────────────────────────────────────────────────

  @impl true
  def spawn_spec(:streaming, ctx) do
    %{
      executable: pi_executable!(),
      args: ["--mode", "rpc"] ++ common_args(ctx),
      env: pi_env(ctx),
      port_opts: [cd: String.to_charlist(ctx.directory)],
      framing: :ndjson
    }
  end

  # `pi -p --mode json` (non-interactive, process-and-exit) emits the exact
  # same event vocabulary as `--mode rpc` to stdout (live-verified) — the
  # :one_shot engine fallback other backends use `codex exec --json`/a `script`
  # PTY wrapper for. No PTY needed here either (plain pipe output is already
  # clean JSONL, live-verified). The prompt is a positional arg, same as
  # Claude/Codex's one-shot spawns.
  def spawn_spec(:one_shot, ctx) do
    prompt = Map.get(ctx, :prompt, "")

    %{
      executable: pi_executable!(),
      args: ["-p", "--mode", "json"] ++ common_args(ctx) ++ [prompt],
      env: pi_env(ctx),
      port_opts: [cd: String.to_charlist(ctx.directory)],
      framing: :ndjson
    }
  end

  # `:orca_hub, :pi_executable` is a test-only seam (drives a real
  # SessionRunner against `test/support/fixtures/pi_stub_rpc.py` instead of a
  # real `pi` install — see OrcaHub.Backend.Pi.PiStubIntegrationTest) — unset
  # in dev/prod, so this falls through to the normal PATH lookup.
  @impl true
  def installed? do
    (Application.get_env(:orca_hub, :pi_executable) || System.find_executable("pi")) != nil
  end

  defp pi_executable! do
    Application.get_env(:orca_hub, :pi_executable) ||
      System.find_executable("pi") ||
      raise "pi executable not found in PATH (install: npm install -g @earendil-works/pi-coding-agent)"
  end

  # ORCA_MCP_URL (spec §12.5): the SAME `/mcp` URL Claude bakes into its
  # inline `--mcp-config` (`Backend.McpUrl.orca_url/1` — one shared builder,
  # so the two backends can never bake different orca_session_id/
  # orchestrator/code_exec query params). `priv/pi/orca-mcp.ts` reads this at
  # `session_start` to discover + register orca's MCP tools; the env var is
  # simply absent for a cold `pi_env/1` call made before a session context
  # exists (there is none — `pi_env/1` always has a real ctx), so the
  # extension's "degrade silently if unset" path only ever fires if URL
  # construction itself fails, not from a missing var in practice.
  #
  # ORCA_IDENTITY (§5.1) rides alongside it, for the same reason `orca-mcp.ts`
  # gets its URL this way: env is invisible to the serving layer's prompt
  # cache, so it is the one channel that can carry per-session bytes into a
  # fork child without moving the inherited prefix. See `orca_identity_json/1`.
  defp pi_env(ctx) do
    extra = [
      {~c"ORCA_MCP_URL", String.to_charlist(OrcaHub.Backend.McpUrl.orca_url(ctx))},
      {~c"ORCA_IDENTITY", String.to_charlist(orca_identity_json(ctx))}
      | provider_api_key_env()
    ]

    if OrcaHub.NodePolicy.scrub_session_env?() do
      OrcaHub.Env.strict_env(extra, OrcaHub.NodePolicy.extra_env_allowlist(ctx.project_id))
    else
      OrcaHub.Env.sanitized_env(extra)
    end
  end

  # pi's real, live-verified auth path is `~/.pi/agent/auth.json`, read
  # straight from the inherited HOME (see the "Session lifecycle" note
  # below) — HOME is in OrcaHub.Env's strict allow-list, so that path
  # survives OrcaHub.NodePolicy.scrub_session_env?/0 with no extra handling.
  # pi ALSO supports bare per-provider env-var auth for any configured
  # provider (`@earendil-works/pi-ai`'s `env-api-keys.js` maps ~30 provider
  # ids to env var names); re-injecting the full list is unnecessary
  # complexity for a fail-open toggle, so this re-injects only the small,
  # obvious subset most likely to be in play (Fireworks — this host's
  # live-verified provider — plus the three big hosted-model vendors) when
  # set on the node. A node relying on a DIFFERENT provider's bare env var
  # (Groq, OpenRouter, etc.) with no `auth.json` would need that var added
  # here — flag if that's needed.
  @pi_provider_api_key_vars ~w(FIREWORKS_API_KEY ANTHROPIC_API_KEY OPENAI_API_KEY GEMINI_API_KEY)

  defp provider_api_key_env do
    Enum.flat_map(@pi_provider_api_key_vars, fn name ->
      case System.get_env(name) do
        nil -> []
        "" -> []
        value -> [{String.to_charlist(name), String.to_charlist(value)}]
      end
    end)
  end

  # Flags shared by :streaming and :one_shot spawns.
  defp common_args(ctx) do
    []
    |> maybe_add_model_arg(ctx[:model])
    |> Kernel.++(["--session-dir", pi_session_dir(ctx)])
    |> maybe_add_fork_or_resume_arg(ctx)
    |> Kernel.++(["--append-system-prompt", system_prompt(ctx)])
    |> Kernel.++(["-e", orca_identity_extension_path()])
    |> Kernel.++(["-e", orca_extension_path()])
    |> Kernel.++(["-e", orca_mcp_extension_path()])
    |> Kernel.++(["-e", orca_plan_extension_path()])
    |> Kernel.++(["-e", orca_guard_extension_path()])
    |> maybe_add_plan_flag(ctx[:plan_mode_pending])
    # Project trust (docs/security.md): non-interactive modes (rpc/json/-p)
    # never show pi's trust prompt — without an explicit decision, pi falls
    # back to `defaultProjectTrust` ("ask" by default), which silently
    # IGNORES project-local `.pi/`/`.agents/` skills, prompts, and
    # extensions. `--approve` trusts them for this run only — the same
    # posture as our Claude usage (unsandboxed, skip-permissions, in
    # user-owned project directories), decided per-spawn by OrcaHub rather
    # than via mutable host-level settings.json state.
    |> Kernel.++(["--approve"])
  end

  # priv/pi/orca.ts — registers the `question` tool (spec §12.3). Resolved via
  # Application.app_dir/2 (not a literal repo-relative path) so this keeps
  # working from an OTP release, where `priv/` is copied alongside the app
  # rather than living at the checkout path — `priv` files ship in releases
  # by default, no extra release config needed.
  defp orca_extension_path, do: Application.app_dir(:orca_hub, "priv/pi/orca.ts")

  # priv/pi/orca-identity.ts — injects the session identity that
  # `system_prompt/1` can no longer carry (pi_fork_spec.md §5.1), read from
  # `ORCA_IDENTITY` at `session_start` exactly like orca-mcp.ts reads
  # `ORCA_MCP_URL`. Loaded FIRST in `common_args/1`, deliberately outside the
  # orca.ts -> orca-plan.ts -> orca-guard.ts ordering contract described in
  # this section: it registers no tools and no `tool_call` handler, so it
  # takes no part in the first-`block: true`-wins chain those three depend
  # on, and going first means identity is queued before anything else runs.
  defp orca_identity_extension_path,
    do: Application.app_dir(:orca_hub, "priv/pi/orca-identity.ts")

  # priv/pi/orca-mcp.ts — bridges the orca `/mcp` endpoint's tools onto
  # dynamically-`pi.registerTool`'d tools (spec §12.5). `pi -e` accepts
  # multiple `--extension`/`-e` flags (verified: `pi --help` documents "can
  # be used multiple times"), so this loads alongside `orca.ts` rather than
  # replacing it.
  defp orca_mcp_extension_path, do: Application.app_dir(:orca_hub, "priv/pi/orca-mcp.ts")

  # priv/pi/orca-plan.ts — read-only plan mode, vendored + adapted from pi's
  # own plan-mode example extension (spec §12.4). Loaded after orca.ts so its
  # PLAN_MODE_TOOLS list can reference the `question` tool orca.ts registers.
  # Same Application.app_dir/2 resolution as above.
  defp orca_plan_extension_path, do: Application.app_dir(:orca_hub, "priv/pi/orca-plan.ts")

  # priv/pi/orca-guard.ts — confirm-before-running gate for force-semantics
  # bash commands (spec §12.7). Loaded LAST (after orca-plan.ts) so pi's
  # per-extension `tool_call` handler ordering (load order, first `block:
  # true` short-circuits — see that file's header) makes plan mode's
  # allowlist block fire before this guard ever runs, composing the two
  # without a double prompt. Same Application.app_dir/2 resolution as above.
  defp orca_guard_extension_path, do: Application.app_dir(:orca_hub, "priv/pi/orca-guard.ts")

  # spec §12.8 — cold plan-mode toggle. `SessionRunner.toggle_plan_mode/1`
  # remembers the desired plan-mode state in runner `data.plan_mode_pending`
  # when it can't write `/plan` to a live port (no `:idle`+warm-port session
  # to talk to). Since `ctx` IS the runner's `data` map at every spawn_spec/2
  # call site (see Backend moduledoc), that pending flag is already present
  # here with zero extra plumbing — this just adds `--plan` (registered by
  # priv/pi/orca-plan.ts via `pi.registerFlag`, spec §12.4) when set, so the
  # NEXT cold spawn starts already in plan mode. `orca-plan.ts`'s
  # `session_start` handler broadcasts `pi_plan_mode` unconditionally
  # (`broadcastPlanState`), so the header badge reconciles to the true
  # post-spawn state regardless of whether this flag actually took effect
  # (e.g. a resumed session's persisted state can override the flag).
  defp maybe_add_plan_flag(args, true), do: args ++ ["--plan"]
  defp maybe_add_plan_flag(args, _pending), do: args

  defp maybe_add_model_arg(args, model) do
    case pi_model(model) do
      nil -> args
      m -> args ++ ["--model", m]
    end
  end

  defp maybe_add_session_id_arg(args, sid) when is_binary(sid) and sid != "" do
    args ++ ["--session-id", sid]
  end

  defp maybe_add_session_id_arg(args, _sid), do: args

  # pi_fork_spec.md §4 — `ctx[:claude_session_id]` is nil exactly on first
  # spawn (inventory #5); every later cold reopen has it set, so `--fork` is
  # structurally unreachable from then on and this falls straight through to
  # the pre-existing `--session-id` resume path. On first spawn, `--fork` is
  # only attempted when `forked_from_session_id` is present — otherwise this
  # is a completely ordinary first spawn (unchanged from before this feature).
  defp maybe_add_fork_or_resume_arg(args, %{claude_session_id: sid} = ctx)
       when is_binary(sid) and sid != "" do
    maybe_add_session_id_arg(args, ctx[:claude_session_id])
  end

  defp maybe_add_fork_or_resume_arg(args, ctx) do
    maybe_add_fork_arg(args, ctx, ctx[:forked_from_session_id])
  end

  defp maybe_add_fork_arg(args, _ctx, nil), do: args
  defp maybe_add_fork_arg(args, _ctx, ""), do: args

  defp maybe_add_fork_arg(args, ctx, parent_id) do
    case resolve_fork_parent_file(ctx, parent_id) do
      {:ok, path} ->
        args ++ ["--fork", path]

      {:error, reason} ->
        Logger.warning(
          "[Backend.Pi] fork requested for session #{ctx.session_id} " <>
            "(parent=#{parent_id}) but could not resolve the parent session " <>
            "file: #{reason} — spawning normally with a blank context instead"
        )

        emit_fork_fallback_warning(ctx, parent_id, reason)
        args
    end
  end

  # spec §4 "Locating the parent file": deterministic dir
  # (`<parent.directory>/.pi_sessions/<parent OrcaHub session id>/`, the SAME
  # pi_session_dir/1 computation below, keyed by the parent's OWN OrcaHub id —
  # NOT this child's), then pick the `*.jsonl` whose header `id` matches the
  # parent's `claude_session_id` (defensive against sibling files ever
  # landing in that dir). Resolved to an absolute path per the spike
  # findings' recommendation #1 (bare-id `--fork` is `--session-dir`-scoped
  # and unusable here; only the absolute-path form works across dirs).
  # Fails soft everywhere: a missing parent row, a parent that hasn't
  # captured a claude_session_id yet (never spawned), an unreadable dir, or
  # no matching file all resolve to `{:error, reason}` rather than raising —
  # the caller degrades to a plain spawn (§4 "fail soft").
  defp resolve_fork_parent_file(ctx, parent_id) do
    case db_call(ctx, :get_session, [parent_id]) do
      nil ->
        {:error, "parent session #{parent_id} not found"}

      %{claude_session_id: nil} ->
        {:error, "parent session #{parent_id} has no claude_session_id yet (never spawned)"}

      %{claude_session_id: ""} ->
        {:error, "parent session #{parent_id} has no claude_session_id yet (never spawned)"}

      %{directory: directory, claude_session_id: claude_sid} ->
        %{directory: directory, session_id: parent_id}
        |> pi_session_dir()
        |> find_parent_session_file(claude_sid)
    end
  rescue
    e -> {:error, "parent session lookup failed: #{Exception.message(e)}"}
  end

  defp find_parent_session_file(dir, claude_session_id) do
    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.find(fn f -> session_file_header_id(Path.join(dir, f)) == claude_session_id end)
        |> case do
          nil -> {:error, "no session file with id #{claude_session_id} found under #{dir}"}
          file -> {:ok, dir |> Path.join(file) |> Path.expand()}
        end

      {:error, reason} ->
        {:error, "cannot read parent session dir #{dir}: #{:file.format_error(reason)}"}
    end
  end

  # Reads only the FIRST line (the session header, `docs/session-format.md`)
  # rather than the whole file — parent histories can be large and only the
  # header's `id` is needed to pick the right file.
  defp session_file_header_id(path) do
    case File.open(path, [:read, :utf8]) do
      {:ok, io} ->
        line = IO.read(io, :line)
        File.close(io)

        with data when is_binary(data) <- line,
             {:ok, %{"id" => id}} <- Jason.decode(data) do
          id
        else
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  # spec §4 "fail soft": persists + broadcasts a visible warning on the
  # child's OWN session topic (same shape/plumbing SessionRunner's
  # persist_message/broadcast use — duplicated here rather than exposed from
  # SessionRunner, mirroring Backend.Claude's own private db_call/3 dup for
  # the identical multi-hub db_node-routing reason) so a fork silently
  # becoming a plain spawn is never invisible. Renders via
  # MessageComponents' generic "system" fallback (raw subtype string) plus
  # its pre-existing "message" extra-text support (same mechanism
  # `pi_notify` events use) — no new UI component needed.
  defp emit_fork_fallback_warning(ctx, parent_id, reason) do
    event = %{
      "type" => "system",
      "subtype" => "fork_fallback",
      "message" =>
        "Could not fork from session #{parent_id} (#{reason}) — " <>
          "started as a normal session with a blank context instead.",
      "timestamp" => NaiveDateTime.utc_now()
    }

    db_call(ctx, :create_message, [%{session_id: ctx.session_id, data: event}])
    broadcast_fork_fallback(ctx.session_id, event)
  rescue
    e ->
      Logger.error(
        "[Backend.Pi] failed to persist/broadcast fork_fallback warning: #{Exception.message(e)}"
      )
  end

  defp broadcast_fork_fallback(session_id, event) do
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "session:#{session_id}", {:event, event})
    Phoenix.PubSub.broadcast(OrcaHub.PubSub, "sessions", {session_id, {:event, event}})
  end

  # Same db_node-routing duplication as Backend.Claude's private db_call/3
  # (multi-hub mode: a session's DB record may be owned by a different node
  # than the one running this spawn) — see that module's comment for why
  # this isn't shared instead.
  defp db_call(%{db_node: db_node}, fun, args) when not is_nil(db_node) and db_node != node() do
    :erpc.call(db_node, HubRPC, fun, args, 10_000)
  end

  defp db_call(_ctx, fun, args) do
    apply(HubRPC, fun, args)
  end

  # pi model handling (mirrors Codex's omit-if-foreign guard, spec step 3):
  # passthrough string; omit when empty or a Claude model id, letting pi fall
  # back to its own default provider/model.
  defp pi_model(nil), do: nil
  defp pi_model(""), do: nil

  defp pi_model(model) do
    if String.starts_with?(model, "claude"), do: nil, else: model
  end

  # `--session-dir` is pi's per-session isolation lever (spec §12.2), pointed
  # at a directory keyed by OrcaHub session id — deterministic, computed
  # identically in spawn_spec/2 and prepare_session/1 (mirrors Codex's
  # CODEX_HOME reasoning, spec §6.3(2)/§10 Q5), so concurrent sessions in the
  # same project directory never collide and cleanup_session/1 only ever
  # removes ITS OWN session's storage, never a sibling's.
  defp pi_session_dir(ctx) do
    Path.join([ctx.directory, ".pi_sessions", to_string(ctx.session_id)])
  end

  # ── Open-time (streaming only) ────────────────────────────────────────
  # No handshake to perform (live-verified: pi accepts a `prompt` as the very
  # first stdin write) — this write exists purely to LEARN the session id via
  # its response (`normalize/2`'s `response{command:"get_state"}` clause),
  # since streaming mode never announces one unprompted. Not a gate: the
  # runner writes the real user turn immediately after this, no FSM/stash.

  @impl true
  def on_open(ctx) do
    {Jason.encode!(%{"type" => "get_state"}) <> "\n", ctx}
  end

  # ── stdin framing (user turns) ────────────────────────────────────────

  @impl true
  def encode_user_turn(prompt, ctx) do
    {Jason.encode!(%{"type" => "prompt", "message" => prompt}) <> "\n", ctx}
  end

  # spec §12.6 — pi's native mid-turn steering command (docs/rpc.md's `steer`,
  # NOT `prompt` + `streamingBehavior`, which is the alternative the docs
  # offer but which this adapter doesn't use). Delivered by pi after the
  # in-flight assistant turn finishes its current tool calls, before the next
  # LLM call — the turn keeps running, unlike Claude/Codex's
  # interrupt-then-resend. Only called by SessionRunner while :running
  # (capabilities().steering: true gates it) — never at open/idle, so no
  # handshake/ordering concerns beyond what encode_user_turn/2 already has.
  @impl true
  def encode_steer_turn(prompt, ctx) do
    {Jason.encode!(%{"type" => "steer", "message" => prompt}) <> "\n", ctx}
  end

  @impl true
  def encode_interrupt(_req_id, %{engine: :one_shot}), do: :signal
  def encode_interrupt(_req_id, _ctx), do: Jason.encode!(%{"type" => "abort"}) <> "\n"

  # ── Normalization (native pi event -> Claude-shaped events) ──────────

  # One-shot `-p --mode json`'s unprompted session-header line (live-verified
  # 0.80.3): first stdout line of every one-shot run.
  @impl true
  def normalize(%{"type" => "session", "id" => sid}, ctx) when is_binary(sid) do
    {[system_init_event(sid)], ctx}
  end

  # Streaming's session id source: the response to on_open/1's get_state.
  def normalize(
        %{"type" => "response", "command" => "get_state", "success" => true, "data" => data},
        ctx
      )
      when is_map(data) do
    case data["sessionId"] do
      sid when is_binary(sid) -> {[system_init_event(sid)], ctx}
      _ -> {[], ctx}
    end
  end

  # Defensive: a rejected prompt (e.g. `success:false` because a prior turn
  # was still streaming and we forgot `streamingBehavior`) would otherwise
  # leave the runner waiting forever for a `result` event that never comes —
  # surface it as an error result instead of hanging.
  def normalize(%{"type" => "response", "command" => "prompt", "success" => false} = resp, ctx) do
    message = resp["error"] || "pi rejected the prompt"
    {[%{"type" => "result", "is_error" => true, "result" => message}], ctx}
  end

  # get_session_stats reply (spec §12.3) — queued by the agent_end clause
  # below via pending_writes, consumed here into a normalized stats event.
  # `data` carries tokens{input,output,cacheRead,cacheWrite,total}, cost
  # (USD), and contextUsage{tokens,contextWindow,percent} verbatim per
  # docs/rpc.md — passed through with snake_case-ish key renaming only where
  # it avoids exposing pi's camelCase straight into the UI layer.
  def normalize(
        %{
          "type" => "response",
          "command" => "get_session_stats",
          "success" => true,
          "data" => data
        },
        ctx
      )
      when is_map(data) do
    {[session_stats_event(data)], ctx}
  end

  # Defensive, spec §12.6, mirrors the "prompt" rejection clause above — a
  # rejected `steer` (e.g. steering was disabled) must NOT synthesize a
  # `result` event (that would end the still-running turn); surface it as a
  # non-terminal persisted system note instead so it's visible but the turn
  # keeps going.
  def normalize(%{"type" => "response", "command" => "steer", "success" => false} = resp, ctx) do
    message = resp["error"] || "pi rejected the steer message"
    {[%{"type" => "system", "subtype" => "steer_failed", "message" => message}], ctx}
  end

  # Every other command response (abort ack, a get_state failure, a failed
  # get_session_stats, …) — no feed event.
  def normalize(%{"type" => "response"}, ctx), do: {[], ctx}

  def normalize(%{"type" => "agent_start"}, ctx) do
    bs = Map.put(ctx.backend_state, :agent_start_ms, System.monotonic_time(:millisecond))
    {[], %{ctx | backend_state: bs}}
  end

  def normalize(
        %{"type" => "message_end", "message" => %{"role" => "assistant", "content" => content}},
        ctx
      )
      when is_list(content) and content != [] do
    blocks = content |> Enum.map(&map_content_block/1) |> Enum.reject(&is_nil/1)
    events = if blocks == [], do: [], else: [assistant_event(blocks)]
    {events, ctx}
  end

  # Aborted-with-empty-content assistant messages, user/toolResult message_end
  # echoes, etc. — dropped (assistant content is emitted exactly once above;
  # tool results come from tool_execution_end below).
  def normalize(%{"type" => "message_end"}, ctx), do: {[], ctx}

  def normalize(%{"type" => "tool_execution_end", "toolCallId" => id} = ev, ctx)
      when is_binary(id) do
    content = get_in(ev, ["result", "content"]) || []
    is_error = ev["isError"] == true

    # Defensive: if a dialog request's own `timeout` (spec §12.3 — set by
    # priv/pi/orca.ts) elapsed, pi auto-resolves it INTERNALLY (no
    # extension_ui_response round-trip, no wire signal at all) — the only
    # observable evidence is the tool that was blocked on it finishing. Clear
    # any stale pending_ui_request now so a later encode_ui_response/3 call
    # for that (already-moot) id correctly no-ops instead of writing a reply
    # pi has already stopped listening for.
    #
    # ORCAHUB3-60: persist a resolution event if the dialog was pending.
    # A dialog that times out produces no pi_ui_response, so we must persist
    # one with resolution: "timeout" so pending_pi_ui_request/1 correctly falls.
    case ctx.backend_state[:pending_ui_request] do
      nil ->
        # No pending dialog - just clear backend_state and continue
        bs = Map.delete(ctx.backend_state, :pending_ui_request)
        {[tool_result_event(id, content, is_error)], %{ctx | backend_state: bs}}

      %{id: dialog_id} ->
        # We have a pending dialog. Check if this tool_execution_end corresponds
        # to the dialog request (id == dialog_id) - pi sends tool_execution_end
        # for the dialog tool when it times out.
        if id == dialog_id do
          # The pending dialog timed out - persist a resolution event
          resolution_event = %{
            "type" => "pi_ui_response",
            "id" => dialog_id,
            "resolution" => "timeout"
          }
          bs = Map.delete(ctx.backend_state, :pending_ui_request)
          {[resolution_event, tool_result_event(id, content, is_error)],
           %{ctx | backend_state: bs}}
        else
          # Different pending dialog - just clear backend_state and continue
          bs = Map.delete(ctx.backend_state, :pending_ui_request)
          {[tool_result_event(id, content, is_error)], %{ctx | backend_state: bs}}
        end
    end
  end

  def normalize(%{"type" => "agent_end", "messages" => messages}, ctx) when is_list(messages) do
    event = agent_end_result(messages, ctx)

    # Spec §12.3: after every completed turn, ask pi for token/cost/context
    # stats. normalize/2 has no direct iodata slot for this — queue it onto
    # backend_state.pending_writes (spec §3.2), flushed by the SAME
    # route_frame/2 pass that called us, right after this event is handled.
    #
    # ORCAHUB3-60: Clear ALL pending dialogs by persisting resolution events.
    # A turn end resolves any still-open dialog that hasn't been answered
    # by structured pi_ui_response. We must close EVERY open dialog, not just
    # an id-matched one (production data: 3 near-simultaneous dialogs where
    # answering one didn't clear the others).
    #
    # We use the same mechanism as SessionRunner.init/1's init sweep:
    # scan all messages for pi_ui_request events without corresponding
    # pi_ui_response events. data.messages is seeded at init from the bounded
    # tail and appended live, so dialogs opened during this turn are present.
    resolution_events =
      case ctx.backend_state[:pending_ui_request] do
        %{id: id} ->
          # First, persist the resolution for the most recent dialog (the one
          # tracked in backend_state) so encode_ui_response/3 can match it
          # if called during this same turn.
          [%{"type" => "pi_ui_response", "id" => id, "resolution" => "turn_end"}]

        nil ->
          []
      end

    # Also scan for any other dialogs that might be open but not tracked in
    # backend_state (e.g., a second dialog opened before the first was answered).
    # Use Sessions.all_pending_pi_dialog_ids/1 to find all unanswered dialogs
    # and persist resolution events for each.
    resolution_events =
      if ctx.session_id do
        pending_ids = OrcaHub.Sessions.all_pending_pi_dialog_ids(ctx.session_id)
        existing_ids = MapSet.new(Enum.map(resolution_events, & &1["id"]))

        Enum.reduce(pending_ids, resolution_events, fn %{"id" => id}, acc ->
          if MapSet.member?(existing_ids, id) do
            acc
          else
            [%{"type" => "pi_ui_response", "id" => id, "resolution" => "turn_end"} | acc]
          end
        end)
      else
        resolution_events
      end

    bs =
      ctx.backend_state
      |> Map.delete(:agent_start_ms)
      |> Map.delete(:pending_ui_request)
      |> Map.put(:pending_writes, [get_session_stats_command()])

    {[event | resolution_events], %{ctx | backend_state: bs}}
  end

  # spec §12.6 — pending steer/follow-up queue changed. Synthesized as a
  # `system`/`queue_update` event: SessionRunner special-cases this exact
  # subtype (mirroring the pre-existing "system"/"status" Claude-compacting
  # clause) to broadcast it WITHOUT persisting to message history — it's
  # ephemeral live state (what's currently queued), not a feed entry, and
  # fires every time the queue changes so persisting it would spam the feed.
  def normalize(%{"type" => "queue_update"} = ev, ctx) do
    event = %{
      "type" => "system",
      "subtype" => "queue_update",
      "steering" => ev["steering"] || [],
      "follow_up" => ev["followUp"] || []
    }

    {[event], ctx}
  end

  # spec §12.6 — compaction lifecycle. Unlike queue_update these ARE
  # persisted feed events (falls through to the generic "system" handling in
  # SessionRunner, same as the synthesized "init" event) — a one-off
  # occurrence worth keeping in history, rendered via MessageComponents'
  # existing system_message/1 path.
  def normalize(%{"type" => "compaction_start", "reason" => reason}, ctx) do
    {[%{"type" => "system", "subtype" => "compaction_start", "reason" => reason}], ctx}
  end

  def normalize(%{"type" => "compaction_end"} = ev, ctx) do
    result = ev["result"] || %{}

    event =
      %{
        "type" => "system",
        "subtype" => "compaction_end",
        "reason" => ev["reason"],
        "aborted" => ev["aborted"] == true
      }
      |> put_if_present("tokens_before", result["tokensBefore"])
      |> put_if_present("estimated_tokens_after", result["estimatedTokensAfter"])
      |> put_if_present("error_message", ev["errorMessage"])

    {[event], ctx}
  end

  # Deltas and everything else (turn_start/turn_end, message_start,
  # message_update, tool_execution_start/update, auto_retry_*,
  # extension_error, …) — drop rather than emit a foreign shape (spec §3.3
  # invariant). turn_end/agent_end embed the same assistant/tool content as
  # message_end/tool_execution_end already emitted from, so re-emitting here
  # would duplicate the feed.
  def normalize(_frame, ctx), do: {[], ctx}

  defp system_init_event(sid),
    do: %{"type" => "system", "session_id" => sid, "subtype" => "init"}

  defp get_session_stats_command, do: Jason.encode!(%{"type" => "get_session_stats"}) <> "\n"

  # A custom (non-Claude-vocabulary) event type — same posture as the
  # pre-existing "cli_error" type (spec §3.3's "emit nothing rather than a
  # foreign shape" rule is about not misusing an EXISTING Claude type, not a
  # ban on genuinely new ones). Rendered by MessageComponents' pi_session_stats
  # case; gated in the UI by capabilities.session_stats.
  defp session_stats_event(data) do
    %{
      "type" => "pi_session_stats",
      "tokens" => data["tokens"],
      "cost" => data["cost"],
      "context_usage" => data["contextUsage"]
    }
  end

  defp assistant_event(blocks),
    do: %{"type" => "assistant", "message" => %{"content" => blocks}}

  defp tool_result_event(id, content, is_error) do
    %{
      "type" => "user",
      "message" => %{
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => id,
            "content" => content,
            "is_error" => is_error
          }
        ]
      }
    }
  end

  # ── AssistantMessage.content -> Claude content blocks (spec §12.2) ────

  defp map_content_block(%{"type" => "text", "text" => text}) when is_binary(text) do
    %{"type" => "text", "text" => text}
  end

  defp map_content_block(%{"type" => "thinking", "thinking" => text}) when is_binary(text) do
    %{"type" => "thinking", "thinking" => text}
  end

  defp map_content_block(%{"type" => "toolCall", "id" => id, "name" => name} = tc)
       when is_binary(id) and is_binary(name) do
    {claude_name, input} = translate_tool(name, tc["arguments"] || %{})
    %{"type" => "tool_use", "id" => id, "name" => claude_name, "input" => input}
  end

  # Unrecognized content block shape — drop rather than emit garbage.
  defp map_content_block(_other), do: nil

  # ── Built-in tool name/argument translation ────────────────────────────
  # pi's own tool ids -> the closest Claude tool name MessageComponents
  # already renders specially, with argument keys translated to match (pi's
  # read/write/edit schemas use "path", Claude's use "file_path"; pi's edit
  # tool supports N replacements via an "edits":[{oldText,newText}] array,
  # Claude's Edit is a single old_string/new_string pair — for v1 multiple
  # edits are folded into one diff block, separator-joined). Tools with no
  # Claude analogue (grep/find/ls, any extension-provided tool) pass through
  # unchanged: MessageComponents' generic tool_icon/summary/detail fallback
  # (wrench icon, empty summary, raw JSON detail) renders any unknown name
  # without crashing (spec §3.3) — verified by reading
  # lib/orca_hub_web/components/message_components.ex's catch-all clauses.

  defp translate_tool("bash", args), do: {"Bash", args}
  defp translate_tool("read", args), do: {"Read", path_input(args)}
  defp translate_tool("write", args), do: {"Write", path_input(args)}
  defp translate_tool("edit", args), do: {"Edit", edit_input(args)}
  defp translate_tool(name, args), do: {name, args}

  defp path_input(args) do
    case args["path"] do
      nil -> args
      path -> Map.put(args, "file_path", path)
    end
  end

  defp edit_input(%{"edits" => edits} = args) when is_list(edits) do
    old = edits |> Enum.map(&(&1["oldText"] || "")) |> Enum.join("\n---\n")
    new = edits |> Enum.map(&(&1["newText"] || "")) |> Enum.join("\n---\n")

    args
    |> path_input()
    |> Map.put("old_string", old)
    |> Map.put("new_string", new)
  end

  defp edit_input(args), do: path_input(args)

  # ── agent_end -> synthesized `result` ──────────────────────────────────
  # pi's protocol has no single "turn completed" summary event (unlike
  # Codex's turn/completed) — agent_end.messages is the full transcript of
  # this run, scanned here (NOT accumulated in backend_state across
  # message_end, avoiding double bookkeeping of the same data) for: the last
  # assistant message's stopReason (error detection — "aborted" is a user
  # stop, not an error, same posture as Codex's turn/completed{interrupted}),
  # its errorMessage, and the sum of every assistant message's usage/cost
  # (pi reports cost directly — unlike Codex, so total_cost_usd IS populated
  # here, read by the result card at message_components.ex ~468).

  defp agent_end_result(messages, ctx) do
    assistant_messages = Enum.filter(messages, &(&1["role"] == "assistant"))
    last_assistant = List.last(assistant_messages)
    is_error = last_assistant != nil and last_assistant["stopReason"] == "error"

    {total_cost, usage} = accumulate_usage(assistant_messages)

    %{"type" => "result", "is_error" => is_error}
    |> put_if_present("duration_ms", duration_ms(ctx))
    |> put_error_message(is_error, last_assistant)
    |> put_if_present("total_cost_usd", total_cost)
    |> put_if_present("usage", usage)
    |> put_if_present("first_response_usage", first_response_usage(assistant_messages))
  end

  defp duration_ms(ctx) do
    case ctx.backend_state[:agent_start_ms] do
      nil -> nil
      start_ms -> System.monotonic_time(:millisecond) - start_ms
    end
  end

  defp put_error_message(map, true, %{"errorMessage" => msg}) when is_binary(msg),
    do: Map.put(map, "result", msg)

  defp put_error_message(map, _is_error, _last_assistant), do: map

  defp put_if_present(map, _key, nil), do: map
  defp put_if_present(map, key, value), do: Map.put(map, key, value)

  # Missing-field tolerance (spec §3.3): no assistant messages at all (should
  # be structurally impossible for agent_end, but stay nil-tolerant) -> omit
  # both total_cost_usd and usage rather than synthesize zeros.
  defp accumulate_usage([]), do: {nil, nil}

  defp accumulate_usage(assistant_messages) do
    totals =
      Enum.reduce(assistant_messages, %{input: 0, output: 0, cache_read: 0, cost: 0.0}, fn msg,
                                                                                           acc ->
        usage = msg["usage"] || %{}
        cost = usage["cost"] || %{}

        %{
          input: acc.input + (usage["input"] || 0),
          output: acc.output + (usage["output"] || 0),
          cache_read: acc.cache_read + (usage["cacheRead"] || 0),
          cost: acc.cost + (cost["total"] || 0.0)
        }
      end)

    usage_shape = %{
      "input_tokens" => totals.input,
      "output_tokens" => totals.output,
      "cache_read_input_tokens" => totals.cache_read
    }

    {totals.cost, usage_shape}
  end

  # ForkGate §6.1 amendment: the accumulated `usage` above is SUMMED across
  # every assistant response in the turn, so a forked child's first turn
  # running a long tool loop inflates `input_tokens` and can false-positive
  # into a spurious cache miss. Only the FIRST response's prompt is exactly
  # [shared system prompt + inherited history + identity entry + first
  # prompt] — the prefix §6.1 actually means to check; later responses in
  # the same turn legitimately have grown inputs (each tool result appends
  # to the prompt) and were never part of what "did this fork hit the
  # cache" is asking. Additive alongside `usage`, not a replacement for it —
  # other code and the UI read the accumulated fields.
  defp first_response_usage([]), do: nil

  defp first_response_usage([first | _rest]) do
    usage = first["usage"] || %{}

    %{
      "input_tokens" => usage["input"] || 0,
      "cache_read_input_tokens" => usage["cacheRead"] || 0
    }
  end

  # ── Peer requests (extension UI protocol) ──────────────────────────────
  # "pi backend groundwork" slice, spec §12.3. Dialog methods
  # (select/confirm/input/editor) — e.g. our own `question` tool
  # (priv/pi/orca.ts) calling `ctx.ui.select`/`ctx.ui.input`, or a FUTURE
  # extension (plan-mode) calling one with no tool_use in flight at all —
  # block pi waiting for an `extension_ui_response`. We do NOT reply here:
  # this is the mid-turn reply-loop's request half. The request is stashed
  # in backend_state (keyed purely on `id`, per spec — never coupled to "a
  # tool_use is in flight") so a LATER `encode_ui_response/3` call (driven by
  # the user answering in the UI) can validate + write the actual reply.
  # Normalized as a NEW event type (spec's "small new component" option,
  # §3.3) rather than force-fit into Claude's AskUserQuestion tool_use/
  # tool_result shape: pi's reply travels back over the wire as a direct
  # `extension_ui_response` port write, not a plain chat turn like Claude's
  # AskUserQuestion answer — conflating the two answer mechanisms under one
  # message shape would make the LiveView's answer path ambiguous about
  # which write path to use. `SessionLive.Show` renders this event via a
  # dedicated modal/card, independent of the AskUserQuestion wizard.
  #
  # Fire-and-forget methods (notify/setStatus/setWidget/setTitle/
  # set_editor_text) expect NO reply — sending one would be protocol noise.
  # `notify` is surfaced as a passive `system`/`pi_notify` event so the user
  # sees it in the feed; the rest (TUI chrome concepts with no OrcaHub
  # analogue) are dropped.

  @impl true
  def handle_peer_request(%{"id" => id, "method" => method} = req, ctx)
      when method in @dialog_ui_methods do
    bs = Map.put(ctx.backend_state, :pending_ui_request, %{id: id, method: method})
    {"", [ui_request_event(req)], %{ctx | backend_state: bs}}
  end

  def handle_peer_request(%{"method" => "notify"} = req, ctx) do
    event = %{
      "type" => "system",
      "subtype" => "pi_notify",
      "message" => req["message"],
      "notify_type" => req["notifyType"] || "info"
    }

    {"", [event], ctx}
  end

  # `priv/pi/orca-plan.ts`'s broadcastPlanState() (spec §12.4) — a
  # fire-and-forget `setStatus` call carrying a JSON-encoded
  # `{"enabled":bool,"executing":bool}` payload in `statusText`, keyed by
  # `statusKey: "orca-plan-mode"` so it's distinguishable from any other
  # extension's status updates. Normalized into a `pi_plan_mode` event (a
  # genuinely new type, spec §3.3) that `SessionLive.Show` uses to learn the
  # TRUE post-toggle state — independent of `ctx.ui.notify`'s free-text
  # message, which is for the human, not for parsing. Fires on every
  # `session_start` too (a resumed/cold-reopened session re-broadcasts its
  # restored state), which is exactly what makes it reliable for
  # reconstruction after a runner restart.
  def handle_peer_request(
        %{"method" => "setStatus", "statusKey" => "orca-plan-mode", "statusText" => text},
        ctx
      )
      when is_binary(text) do
    event =
      case Jason.decode(text) do
        {:ok, %{"enabled" => enabled} = data} ->
          [
            %{
              "type" => "pi_plan_mode",
              "enabled" => enabled == true,
              "executing" => data["executing"] == true
            }
          ]

        _ ->
          []
      end

    {"", event, ctx}
  end

  def handle_peer_request(%{"method" => _fire_and_forget}, ctx), do: {"", [], ctx}

  defp ui_request_event(req) do
    %{
      "type" => "pi_ui_request",
      "id" => req["id"],
      "method" => req["method"],
      "title" => req["title"],
      "message" => req["message"],
      "options" => req["options"],
      "placeholder" => req["placeholder"],
      "prefill" => req["prefill"]
    }
  end

  # ── Extension-UI reply loop: the answer half ────────────────────────────
  # Called by SessionRunner.answer_ui_request/3 (a mid-turn-allowed GenStatem
  # call — the dialog blocks the CURRENT turn, so the runner must be in
  # :running when this fires) via the Backend.encode_ui_response/4
  # dispatcher. Validates `request_id` against the SAME pending request
  # `handle_peer_request/2` stashed above; an unknown or already-answered id
  # (double submit, stale reload, a response for a request this backend_state
  # was reset for — e.g. after a cold reopen) is a no-op rather than a wire
  # write, per spec.
  @impl true
  def encode_ui_response(request_id, payload, ctx) do
    case ctx.backend_state[:pending_ui_request] do
      %{id: ^request_id} ->
        bs = Map.delete(ctx.backend_state, :pending_ui_request)
        body = Map.merge(%{"type" => "extension_ui_response", "id" => request_id}, payload)
        {:ok, Jason.encode!(body) <> "\n", %{ctx | backend_state: bs}}

      _ ->
        :noop
    end
  end

  # ── Plan mode toggle (spec §12.4) ───────────────────────────────────────
  # Called by SessionRunner.toggle_plan_mode/1 (only reachable from :idle
  # with a warm port — never mid-turn) via the Backend.encode_toggle_plan_mode/2
  # dispatcher. `priv/pi/orca-plan.ts` registers `/plan` as a toggle-only
  # extension COMMAND (no arguments): extension commands are handled
  # synchronously by pi and do NOT start an agent turn (live-verified against
  # 0.80.3 — no `agent_start`/`agent_end` fires, `get_state.messageCount`
  # stays unchanged), so this reuses encode_user_turn/2's exact wire shape
  # (`{"type":"prompt","message":…}`) rather than a bespoke frame — pi
  # dispatches on the leading "/plan" before ever reaching agent processing.
  @impl true
  def encode_toggle_plan_mode(ctx) do
    {iodata, new_ctx} = encode_user_turn("/plan", ctx)
    {:ok, iodata, new_ctx}
  end

  # ── Manual compaction (spec §12.8) ──────────────────────────────────────
  # Called by SessionRunner.compact_session/1 (only reachable from :idle with
  # a warm port — mirrors toggle_plan_mode/1's gating exactly) via the
  # Backend.encode_compact/2 dispatcher. pi's `compact` RPC command
  # (docs/rpc.md) triggers `compaction_start`/`compaction_end` events that
  # Backend.Pi.normalize/2 already normalizes onto persisted `system` events
  # (spec §12.6) — no further wiring needed here.
  @impl true
  def encode_compact(ctx) do
    {:ok, Jason.encode!(%{"type" => "compact"}) <> "\n", ctx}
  end

  # ── Session id extraction ───────────────────────────────────────────────

  @impl true
  def session_id(%{"type" => "system", "session_id" => sid}) when is_binary(sid), do: sid
  def session_id(_event), do: nil

  # ── Session lifecycle (--session-dir storage) ───────────────────────────
  # No auth copying needed (unlike Codex's per-session CODEX_HOME hiding
  # ~/.codex/auth.json): pi reads ~/.pi/agent/auth.json straight from HOME,
  # which the spawned child inherits unchanged (OrcaHub.Env.sanitized_env/0
  # only unsets RELEASE_* vars and cleans PATH — HOME passes through);
  # live-verified real Fireworks-provider turns succeeded with no HOME/auth
  # handling in this adapter at all.

  @impl true
  def prepare_session(ctx) do
    File.mkdir_p!(pi_session_dir(ctx))
    :ok
  rescue
    e ->
      Logger.error("[Backend.Pi] prepare_session failed: #{Exception.message(e)}")
      :ok
  end

  @impl true
  def cleanup_session(ctx) do
    File.rm_rf(pi_session_dir(ctx))
    :ok
  rescue
    _ -> :ok
  end

  # ── System prompt (:flag — --append-system-prompt) ─────────────────────
  # Reuses the non-Claude-specific SharedPrompts fragments like Codex does.
  # As of the orca-mcp bridge (spec §12.5, capabilities.mcp == true), the
  # MCP-dependent fragments are no longer inapplicable — `orca-mcp.ts`
  # registers orca's tools under the exact same `mcp__orca__<tool>` names
  # Claude uses, so `SharedPrompts.orchestrator_prompt/3`'s
  # `mcp__orca__start_session`-shaped guidance (moved out of `Backend.Claude`
  # into `SharedPrompts` for exactly this reuse) and the code-exec prompt are
  # both included here now, mirroring `Backend.Claude.system_prompt/1`
  # closely (this backend still has no AskUserQuestion-fallback text or
  # sibling-session prompt — out of scope for the MCP bridge itself).
  # Deliberately DOES NOT include `SharedPrompts.context_files_prompt/1`
  # (unlike Claude/Codex) — inlining the whole `.context/*.{md,mmd}` doc set
  # verbatim is by far the largest fragment and was blowing up pi sessions'
  # context budget at startup; Claude and Codex still get it.
  #
  # ── FLAGS ONLY: no per-session bytes may appear here (§5.1) ────────────
  # This string is `--append-system-prompt`'s value, i.e. byte 0 of the
  # prompt. A forked child (§4) only gets its cheap warm resume if its
  # inherited prefix is byte-identical to the parent's, and the serving layer
  # matches longest-common-prefix from byte 0 — so ONE differing byte here
  # discards cache reuse of the entire prefix (~26s cold prefill instead of
  # ~2s, plus it craters every co-tenant on the shared llama-server).
  #
  # So `system_prompt/1` is now a PURE FUNCTION of
  # `(orchestrator, code_exec, commit_trailer)`. The four fragments that used
  # to diverge per session moved into `ORCA_IDENTITY` (`orca_identity_json/1`
  # below) and are delivered by `priv/pi/orca-identity.ts` as a
  # `custom_message` session entry instead:
  #
  #   1. the "Your OrcaHub session ID is …" line
  #   2. `SharedPrompts.commit_trailer_prompt/1`  (embeds the id)
  #   3. `SharedPrompts.issue_commit_trailer_prompt/1` (embeds the issue key)
  #   4. `SharedPrompts.open_issues_prompt/1` — a LIVE DB query, so it varied
  #      per session AND per moment; it was already busting same-session
  #      prefix caching on every cold reopen, forks aside.
  #
  # `orchestrator_prompt/3` and `worker_practices_prompt/2` still take a
  # session id but ignore it (`_session_id`), so they are not divergence
  # sources and stay exactly as they were.
  #
  # `commit_trailer` remains a *flag* input: when the project has opted out,
  # the model should not be told about a trailer convention at all. The
  # generic reminder below is id-free, so two sessions with the same flags
  # still render identical bytes; the concrete `OrcaHub-Session: <id>` line
  # rides the identity entry.
  #
  # This determinism is pinned by "system_prompt/1 — byte determinism" in
  # test/orca_hub/backend/pi_test.exs. Claude and Codex are UNAFFECTED (they
  # keep all four fragments inline) and are byte-pinned by the golden fence in
  # their own test files — `SharedPrompts` was extended, never mutated.

  @impl true
  def system_prompt(ctx) do
    code_exec = OrcaHub.MCP.CodeExec.enabled?(Map.get(ctx, :code_exec, false))

    [
      SharedPrompts.orchestrator_prompt(ctx.orchestrator, nil, code_exec),
      SharedPrompts.code_exec_prompt(code_exec),
      if(ctx.orchestrator, do: fork_timing_prompt()),
      if(Map.get(ctx, :commit_trailer, true), do: commit_trailer_flag_prompt()),
      if(!ctx.orchestrator, do: SharedPrompts.worker_practices_prompt(true, code_exec))
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n\n")
  end

  # pi-ONLY, and deliberately not in `SharedPrompts`: forking is a pi-native
  # primitive, and Claude's/Codex's rendered prompts are byte-pinned by the
  # golden fence in `test/support/fixtures/prompt_goldens/`. A fixed constant
  # string keeps `system_prompt/1` a pure function of its three flags (§5.1),
  # so it costs nothing in fork determinism.
  #
  # Why it earns its bytes: `fork_from_parent` forks the CALLER, so the gate
  # (§6) must hold the first child until the caller's CURRENT turn ends —
  # otherwise the caller's own next LLM call keeps the slot that caches the
  # inherited prefix and the child cold-prefills (measured 3/3, 25.7-32.0s).
  # The gate's wait is for the WHOLE turn, so an orchestrator that forks and
  # then works for another five minutes holds its own children that long.
  # One sentence of guidance converts that worst case into the best case.
  defp fork_timing_prompt do
    """
    When you spawn forked children (`fork_from_parent`), make those spawns \
    the LAST action of your turn and end the turn promptly. A fork inherits \
    your session's cached context, and the first child's prompt is held \
    until YOUR current turn finishes — until then your own turn is still \
    holding the cache that makes the fork cheap. Fork, then stop; don't fork \
    and keep working.\
    """
    |> String.trim()
  end

  # The id-free half of the commit-trailer instruction — the part that is a
  # function of the flag alone. Its `OrcaHub-Session: <id>` counterpart
  # (`SharedPrompts.commit_trailer_prompt/1`, unchanged and still used
  # verbatim by Claude/Codex) is delivered via ORCA_IDENTITY, which is also
  # what re-states it with the CHILD's id at a fork's divergence point.
  defp commit_trailer_flag_prompt do
    """
    Every git commit you make must carry an `OrcaHub-Session:` git trailer \
    naming your session id. Your session id, and the exact trailer to use, \
    are given to you in the `orca-identity` message in this conversation — \
    always take the id from the LATEST such message, since it changes if \
    this session was forked from another one.\
    """
    |> String.trim()
  end

  # ── ORCA_IDENTITY (§5.1) ──────────────────────────────────────────────
  # Everything `system_prompt/1` can no longer say, in one env-var payload.
  # Env is invisible to the KV cache, so this varying per session — and per
  # fork child — costs nothing, unlike the same text in the system prompt.
  #
  # `priv/pi/orca-identity.ts` consumes it at `session_start` and appends it
  # as a `custom_message` entry ONLY when the latest existing identity entry
  # names a different session id. That single rule covers both cases with no
  # fork-specific code: a cold reopen no-ops (stable prefix), and a fork child
  # — whose inherited history names the PARENT — appends one identity update
  # exactly at the divergence point.
  #
  # Gating mirrors what `system_prompt/1` used to do here, deliberately
  # including pi's two deviations from Claude/Codex: the trailer fragments are
  # gated on the `commit_trailer` flag ALONE (no `!orchestrator` gate), and
  # the open-issues resume hook is unconditional.
  defp orca_identity_json(ctx) do
    commit_trailer? = Map.get(ctx, :commit_trailer, true)
    issue_key = Map.get(ctx, :issue_key)

    %{
      "session_id" => to_string(ctx.session_id),
      "commit_trailer" =>
        if(commit_trailer?, do: SharedPrompts.commit_trailer_prompt(ctx.session_id)),
      "issue_trailer" =>
        if(commit_trailer? && issue_key,
          do: SharedPrompts.issue_commit_trailer_prompt(issue_key)
        ),
      "open_issues" => SharedPrompts.open_issues_prompt(ctx.session_id)
    }
    |> Jason.encode!()
  end
end
