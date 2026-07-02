defmodule OrcaHub.SessionSupervisor do
  @moduledoc """
  DynamicSupervisor for `SessionRunner` processes.
  """

  use DynamicSupervisor

  alias OrcaHub.Backend

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  def start_session(session_id, session_data \\ nil, db_node \\ nil) do
    opts =
      [session_id: session_id]
      |> then(fn o -> if session_data, do: o ++ [session_data: session_data], else: o end)
      |> then(fn o -> if db_node, do: o ++ [db_node: db_node], else: o end)

    spec = {OrcaHub.SessionRunner, opts}
    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  def stop_session(session_id) do
    result =
      case Registry.lookup(OrcaHub.SessionRegistry, session_id) do
        [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
        [] -> {:error, :not_found}
      end

    # Update DB status and broadcast so LiveViews update immediately
    case result do
      :ok ->
        try do
          session = OrcaHub.HubRPC.get_session!(session_id)

          if session.status in ~w(running waiting compacting) do
            OrcaHub.HubRPC.update_session(session, %{status: "error"})
          end

          cleanup_backend_state(session)
        rescue
          # Defensive boundary: this is a best-effort status sync after the
          # session is already terminated. The DB record may be gone, or the
          # hub node unreachable — neither should fail stop_session/1.
          _ -> :ok
        end

        Phoenix.PubSub.broadcast(OrcaHub.PubSub, "session:#{session_id}", {:status, :error})
        :ok

      error ->
        error
    end
  end

  # `DynamicSupervisor.terminate_child/2` above sends the child a raw exit
  # signal; `SessionRunner` (a `:gen_statem`) never calls
  # `Process.flag(:trap_exit, true)`, so its `terminate/3` callback — which
  # normally runs `backend.cleanup_session/1` (e.g. Codex's per-session
  # `CODEX_HOME` removal) — never fires on THIS path (backend_abstraction_spec.md
  # §10 Q5's trap_exit addendum). `terminate/3` DOES still run for a crash or
  # an internal `{:stop, reason}` return, so this gap is specific to an
  # explicit `stop_session/1` call.
  #
  # Fixed the narrow way instead of flipping `trap_exit` globally (which would
  # change shutdown semantics for every crash/exit path, not just this one):
  # `cleanup_session/1` only needs `directory`/`session_id` off the DB record
  # — no live runner process required — so call it directly here, once the
  # child is confirmed terminated. A no-op for Claude (`cleanup_session/1` is
  # `:ok`); for Codex it removes the `CODEX_HOME` directory.
  defp cleanup_backend_state(session) do
    Backend.resolve(session.backend).cleanup_session(%{
      directory: session.directory,
      session_id: session.id
    })

    :ok
  end

  def session_alive?(session_id) do
    Registry.lookup(OrcaHub.SessionRegistry, session_id) != []
  end
end
