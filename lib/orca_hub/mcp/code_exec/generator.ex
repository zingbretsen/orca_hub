defmodule OrcaHub.MCP.CodeExec.Generator do
  @moduledoc """
  Serializes (re)generation of the global `Tools` surface.

  The `Tools` module is a single global atom shared by every code-exec session
  on this node. Regenerating it is `Module.create/3`, which loads a new code
  version and **hard-purges** any lingering "old" version — which would kill an
  in-flight `run_elixir` eval running that old version. This GenServer makes
  regeneration safe:

    * **Serialized** — a single process does all `Module.create` calls, so two
      concurrent `ensure!/0` callers can never race two loads (which is the only
      way the hard purge can hit live code).
    * **Signature-gated** — regenerate only when the live registry's signature
      changes (the upstream cache refreshes every ~5 min; first-party tools are
      compile-time). The common case is a cheap hash compare, no recompile.
    * **Soft-purge-gated** — before loading, `:code.soft_purge/1` clears the
      prior "old" version only if no process is running it. If an eval is still
      on it (unusual — evals are timeout-bounded), we skip this round and keep
      serving the current module; the new tool shows up after that eval ends.

  Reads are lock-free: generated code calls the `Tools.*` functions directly.
  Only (re)generation goes through this process.
  """
  use GenServer

  require Logger

  alias OrcaHub.MCP.CodeExec.ToolGen

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Ensure the global `Tools` surface reflects the current live registry,
  regenerating it if the registry signature changed since the last generation.
  Synchronous so the caller (a sandbox eval) sees an up-to-date module.
  """
  def ensure!(timeout \\ 15_000) do
    GenServer.call(__MODULE__, :ensure, timeout)
  catch
    # If the Generator is unavailable, fall back to a best-effort direct
    # generation so code-exec still works (e.g. in a bare test VM). Not
    # serialized, but better than failing the eval.
    :exit, _ ->
      ToolGen.generate()
      :ok
  end

  @impl true
  def init(_opts), do: {:ok, %{signature: nil}}

  @impl true
  def handle_call(:ensure, _from, %{signature: sig} = state) do
    tools = ToolGen.live_tools()
    current = ToolGen.signature(tools)

    cond do
      current == sig ->
        {:reply, :ok, state}

      not generated?() ->
        # First generation on this node — nothing to purge.
        ToolGen.generate(tools: tools)
        {:reply, :ok, %{state | signature: current}}

      :code.soft_purge(Tools) ->
        # Prior "old" version (if any) is free; safe to load a new version.
        ToolGen.generate(tools: tools)
        {:reply, :ok, %{state | signature: current}}

      true ->
        # An in-flight eval still holds the old code — keep the current module
        # and re-resolve on the next ensure! once that eval has finished.
        Logger.info("[code_exec] Tools regeneration deferred — old version in use")
        {:reply, :ok, state}
    end
  end

  defp generated?, do: Code.ensure_loaded?(Tools) and function_exported?(Tools, :list, 0)
end
