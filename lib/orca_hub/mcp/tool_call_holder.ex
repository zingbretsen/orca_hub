defmodule OrcaHub.MCP.ToolCallHolder do
  @moduledoc """
  Behaviour for a "holder" record `OrcaHub.MCP.Server`'s client-tool-call
  parking machinery can drive — a row that declares `result_schema`/
  `client_tools` for one session and tracks at most one outstanding
  `pending_tool_call` at a time.

  Extracted from the Agent Runs API's `api_runs` table (docs/api.md) so the
  exact same parking mechanics (park, hold-timeout, poll fallback, PubSub
  resolution, idempotent re-park on restart) are reused, unmodified, by the
  inbound A2A v2 tool-call loop (docs/a2a.md) against `a2a_tasks` — see
  `ApiRunHolder` and `A2ATaskHolder`. A concrete holder wraps a
  schema/struct with matching field names (`result_schema`, `client_tools`,
  `pending_tool_call`, `timeout_seconds`, `inserted_at`, `session_id`) so
  `MCP.Server`'s shared code can read those fields directly off whichever
  holder struct it's handed, without a holder-specific accessor for each
  one.
  """

  @type holder :: struct()

  @doc "The most recently created holder for a session, or `nil`."
  @callback get_by_session_id(session_id :: String.t()) :: holder() | nil

  @doc "Fetch a holder by its own id."
  @callback get(id :: String.t()) :: holder() | nil

  @doc "Persist an attribute update onto a holder, returning the updated record."
  @callback update(holder(), attrs :: map()) :: {:ok, holder()} | {:error, Ecto.Changeset.t()}

  @doc "The PubSub topic a caller broadcasts an answer on for this holder id."
  @callback topic(id :: String.t()) :: String.t()

  @doc "The status value to set while a client tool call is parked."
  @callback parked_status() :: String.t()

  @doc "The status value to set once a parked call resolves and the turn resumes."
  @callback resumed_status() :: String.t()

  @doc "Every registered holder module, tried in order by session-id lookup."
  @spec modules() :: [module()]
  def modules,
    do: [OrcaHub.MCP.ToolCallHolder.ApiRunHolder, OrcaHub.MCP.ToolCallHolder.A2ATaskHolder]

  @doc """
  Finds the holder (if any) backing `session_id`, trying each registered
  module in order — a session is only ever backed by ONE holder kind
  (created by exactly one of `ApiRunController`/`A2AController`), so the
  first non-nil match wins. Returns `{module, holder}` or `nil`.
  """
  @spec find_by_session_id(String.t()) :: {module(), holder()} | nil
  def find_by_session_id(session_id) do
    Enum.find_value(modules(), fn mod ->
      case mod.get_by_session_id(session_id) do
        nil -> nil
        holder -> {mod, holder}
      end
    end)
  end
end
