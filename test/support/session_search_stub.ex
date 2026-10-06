defmodule OrcaHub.SessionSearchStub do
  @moduledoc """
  Stand-in for `OrcaHub.MemoryClient` in session-search tests. Set it with
  `OrcaHub.SessionSearchStub.install(response)`; it reports each call's params
  to the installing test process as `{:session_search_params, params}` and
  returns `response`. Uses app env (not the process dictionary) because
  LiveView/runner processes make the call. Tests using it must be `async: false`.
  """

  def install(response) do
    Application.put_env(:orca_hub, :session_search_client, __MODULE__)
    Application.put_env(:orca_hub, :session_search_stub, {self(), response})

    ExUnit.Callbacks.on_exit(fn ->
      Application.delete_env(:orca_hub, :session_search_client)
      Application.delete_env(:orca_hub, :session_search_stub)
    end)
  end

  def search_session_messages(params) do
    {pid, response} = Application.fetch_env!(:orca_hub, :session_search_stub)
    send(pid, {:session_search_params, params})
    if is_function(response, 1), do: response.(params), else: response
  end

  def result(session_id, opts \\ []) do
    %{
      "group_id" => session_id,
      "score" => opts[:score] || 0.03,
      "legs" => ["bm25", "knn"],
      "hits" => [
        %{
          "id" => Ecto.UUID.generate(),
          "chunk_index" => 0,
          "score" => 1.0,
          "highlights" => [opts[:highlight] || "the \u0002needle\u0003 here"],
          "fields" => %{"role" => "user", "inserted_at" => "2026-10-06T12:00:00Z"}
        }
      ]
    }
  end
end
