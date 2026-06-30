defmodule OrcaHub.NodeCredentials do
  @moduledoc """
  Context for per-node Claude Code OAuth tokens.

  Tokens are captured by the "Log in this node" flow (`claude setup-token`,
  see `OrcaHub.LoginRunner`) and stored keyed by Erlang node name. When a
  `claude` port is spawned on a node that has a stored token, the token is
  injected as `CLAUDE_CODE_OAUTH_TOKEN` so sessions authenticate without a
  local `credentials.json`.

  This module talks to the database directly and therefore only runs on the
  hub. Callers on any node must go through `OrcaHub.HubRPC`.

  Security: tokens are long-lived secrets — never log or render the value.
  """

  import Ecto.Query

  alias OrcaHub.NodeCredentials.NodeCredential
  alias OrcaHub.Repo

  @doc "Return the stored OAuth token for `node_name`, or `nil` if none."
  def get_token_for_node(node_name) when is_binary(node_name) do
    case Repo.get_by(NodeCredential, node_name: node_name) do
      nil -> nil
      %NodeCredential{oauth_token: token} -> token
    end
  end

  @doc "Insert or update the OAuth token for `node_name` (upsert on node_name)."
  def put_token_for_node(node_name, token)
      when is_binary(node_name) and is_binary(token) do
    %NodeCredential{}
    |> NodeCredential.changeset(%{node_name: node_name, oauth_token: token})
    |> Repo.insert(
      on_conflict: [set: [oauth_token: token, updated_at: DateTime.utc_now()]],
      conflict_target: :node_name
    )
  end

  @doc "Delete the stored credential for `node_name` (logs the node out)."
  def delete_for_node(node_name) when is_binary(node_name) do
    {count, _} =
      Repo.delete_all(from c in NodeCredential, where: c.node_name == ^node_name)

    {:ok, count}
  end

  @doc """
  List node names that have a stored credential. Returns only the node name
  strings — never the token values — so it is safe to expose to the UI.
  """
  def list_logged_in_nodes do
    Repo.all(from c in NodeCredential, select: c.node_name)
  end

  @doc """
  Build the Erlang port `:env` extra list for a token. Returns `[]` when there
  is no token so callers never clobber a node that authenticates via
  `credentials.json`. Pure — safe to unit test without a database.
  """
  def token_env(token) when is_binary(token) and token != "" do
    [{~c"CLAUDE_CODE_OAUTH_TOKEN", String.to_charlist(token)}]
  end

  def token_env(_), do: []
end
