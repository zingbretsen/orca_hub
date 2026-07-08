defmodule OrcaHub.MCP.CodeExec do
  @moduledoc """
  "Code execution with MCP" — let a session write real Elixir that calls tools
  as named functions (`Tools.github__…` etc.) and stitches results with stdlib,
  instead of the flat one-call-at-a-time `tools/list` + `tools/call` surface.

  This module is the feature's front door:

    * **resolution / kill switch** — `enabled?/1` / `disabled?/0` decide whether
      a session runs in code-exec mode, honoring the `ORCA_DISABLE_CODE_EXEC`
      env kill switch (mirrors the streaming engine's `ORCA_DISABLE_STREAMING`).
    * **per-eval state** — `put_state/1` / `get_state/0` thread the caller's MCP
      `state` (`%{orca_session_id:, orchestrator:}`) through the **process
      dictionary** of the eval Task. The generated `Tools.*` functions read it
      from there, so per-session state is NOT baked into a per-session module
      name (which would grow the never-GC'd atom table).
    * **run/3** — ensure the live `Tools` surface is generated, then evaluate a
      snippet in the sandbox with the given MCP state installed and the
      session's persisted variable binding threaded in/out (see
      `…CodeExec.BindingStore`), so variables survive across `run_elixir`
      calls within the same session — like a REPL/notebook.

  ## On by default, opt-out per session

  Code-exec collapses a session's `tools/list` down to two meta-tools
  (`run_elixir`, `search_tools`) and routes everything else through
  generated Elixir. This is **on by default for new sessions** but remains a
  per-session setting you can turn **off** (opt-out) — the `sessions.code_exec`
  column, carried into the `/mcp` URL by `SessionRunner`, exactly like the
  `orchestrator` flag. It is globally killable via `ORCA_DISABLE_CODE_EXEC`,
  which force-disables it node-wide regardless of any per-session setting. When
  OFF, `tools/list` / `tools/call` behave exactly as before.

  See `OrcaHub.MCP.CodeExec.Sandbox` for the evaluator, `…ToolGen` /
  `…Generator` for the generated `Tools` surface, and `…MetaTools` for the
  collapsed MCP tool set.
  """

  alias OrcaHub.MCP.CodeExec.{BindingStore, Generator, Sandbox}

  @state_key {__MODULE__, :state}

  # Suggested budget: don't let one session's binding grow unbounded. Over
  # budget, the eval's own return value is unaffected — only persistence for
  # the *next* call is skipped. Overridable via config (tests use a tiny
  # budget instead of constructing multi-megabyte fixtures).
  @default_binding_budget_bytes 5 * 1024 * 1024

  @doc """
  Whether code-exec mode is active for a connection.

  Accepts the MCP server `state` map (reads `:code_exec`) or a raw boolean.
  Always `false` when the `ORCA_DISABLE_CODE_EXEC` kill switch is set, so a
  stale `code_exec=true` query param can never re-enable the feature node-wide.
  """
  def enabled?(%{code_exec: code_exec}), do: enabled?(code_exec)
  def enabled?(true), do: not disabled?()
  def enabled?(_), do: false

  @doc "True if the `ORCA_DISABLE_CODE_EXEC` env kill switch is set on this node."
  def disabled?, do: Application.get_env(:orca_hub, :disable_code_exec, false)

  @doc "Install the MCP `state` for the current (eval) process. Returns `state`."
  def put_state(state) do
    Process.put(@state_key, state)
    state
  end

  @doc "Read the MCP `state` installed for the current process (default `%{}`)."
  def get_state, do: Process.get(@state_key, %{})

  @doc """
  Evaluate model-authored `code` in the sandbox with `state` installed.

  Threads a persistent variable binding, keyed by the session's
  `orca_session_id` (falling back to the MCP `session_id` when nil — e.g.
  connections without an orca session, so the feature still degrades
  gracefully within a turn) through `BindingStore`, so variables assigned in
  one `run_elixir` call are visible in the next. Only a **successful** eval
  updates the stored binding — a rejected/raised/timed-out eval leaves the
  previous binding untouched. If the new binding exceeds the byte budget
  (default #{@default_binding_budget_bytes}, see `:code_exec_binding_budget_bytes`)
  it is NOT saved (the old binding is kept) and a one-line notice is attached
  under `:note`; the eval's own return value is unaffected.

  `opts[:reset]` clears the stored binding before evaluating, so the snippet
  runs against a fresh (empty) binding.

  Ensures the global `Tools` surface reflects the live registry, then delegates
  to `Sandbox.eval/2`. Returns the sandbox result tuple (with `:binding`
  replaced by an optional `:note` on success); `MetaTools` formats it into an
  MCP result for `run_elixir`.
  """
  def run(code, state, opts \\ []) when is_binary(code) do
    Generator.ensure!()
    {reset?, opts} = Keyword.pop(opts, :reset, false)
    key = binding_key(state)

    if reset?, do: BindingStore.reset(key)
    binding = BindingStore.get(key)

    code
    |> Sandbox.eval(Keyword.merge(opts, state: state, binding: binding))
    |> persist_binding(key)
  end

  defp binding_key(%{orca_session_id: id}) when not is_nil(id), do: id
  defp binding_key(%{session_id: id}) when not is_nil(id), do: id
  defp binding_key(_state), do: nil

  defp persist_binding({:ok, %{value: value, stdout: stdout, binding: binding}}, key) do
    size = :erlang.external_size(binding)
    budget = binding_budget_bytes()

    if size <= budget do
      BindingStore.put(key, binding)
      {:ok, %{value: value, stdout: stdout}}
    else
      note =
        "[bindings not saved: #{size} bytes exceeds the #{budget} byte budget " <>
          "— bind smaller values]"

      {:ok, %{value: value, stdout: stdout, note: note}}
    end
  end

  defp persist_binding(error, _key), do: error

  defp binding_budget_bytes do
    Application.get_env(
      :orca_hub,
      :code_exec_binding_budget_bytes,
      @default_binding_budget_bytes
    )
  end
end
