defmodule OrcaHubWeb.VersionEndpointTest do
  @moduledoc """
  GET /api/version is handled directly in the Endpoint (like /healthz),
  ahead of the Router pipeline — so it's reachable with no session/auth
  plugs applied. See lib/orca_hub_web/endpoint.ex.
  """

  use OrcaHubWeb.ConnCase, async: true

  test "GET /api/version returns sha and built_at with no auth", %{conn: conn} do
    conn = get(conn, "/api/version")

    assert conn.status == 200
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")

    assert %{"sha" => sha, "built_at" => built_at} = Jason.decode!(conn.resp_body)
    assert is_binary(sha) and sha != ""
    assert {:ok, _, _} = DateTime.from_iso8601(built_at)
  end
end
