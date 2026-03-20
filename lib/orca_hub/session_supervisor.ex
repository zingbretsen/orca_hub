defmodule OrcaHub.SessionSupervisor do
  use DynamicSupervisor

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
    case Registry.lookup(OrcaHub.SessionRegistry, session_id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      [] -> {:error, :not_found}
    end
  end

  def session_alive?(session_id) do
    Registry.lookup(OrcaHub.SessionRegistry, session_id) != []
  end
end
