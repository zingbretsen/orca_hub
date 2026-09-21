defmodule OrcaHubWeb.DrainEndpointTest do
  @moduledoc """
  GET /api/drain is handled directly in the Endpoint (like /healthz and
  /api/version), ahead of the Router pipeline, and allow-listed through
  `:agent_mode_gate` so the mini/gb10/local agents serve it. See
  lib/orca_hub_web/endpoint.ex and `OrcaHub.DrainStatus`.

  async: false — the hub-unreachable tests flip :orca_hub's :mode app env,
  which is global process state (same reasoning as
  test/orca_hub_web/agent_mode_gate_test.exs).
  """

  use OrcaHubWeb.ConnCase, async: false

  alias OrcaHub.Jobs
  alias OrcaHub.Sessions

  @this_node to_string(node())

  setup do
    prev = Application.get_env(:orca_hub, :mode, :hub)
    on_exit(fn -> Application.put_env(:orca_hub, :mode, prev) end)
    :ok
  end

  defp create_session(attrs) do
    {:ok, session} =
      Sessions.create_session(
        Map.merge(%{directory: "/tmp/drain-test", runner_node: @this_node}, attrs)
      )

    session
  end

  describe "hub mode — the question is answerable" do
    test "reports safe_to_restart when nothing is in flight on this node", %{conn: conn} do
      # Sessions/jobs owned by ANOTHER node must not hold this one back.
      create_session(%{status: "running", runner_node: "someone-else@nohost"})

      {:ok, _} =
        Jobs.create_job(%{
          directory: "/tmp",
          runner_node: "someone-else@nohost",
          command: "sleep 1"
        })

      # Nor must a finished session on this node.
      create_session(%{status: "idle", title: "done"})

      conn = get(conn, "/api/drain")

      assert conn.status == 200
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")

      body = Jason.decode!(conn.resp_body)
      assert body["safe_to_restart"] == true
      assert body["state"] == "ok"
      assert body["node"] == @this_node
      assert body["sessions"]["active"] == 0
      assert body["sessions"]["items"] == []
      assert body["jobs"]["nonterminal"] == 0
    end

    test "refuses and names the in-flight sessions on this node", %{conn: conn} do
      running = create_session(%{status: "running", title: "Deploy the thing"})
      waiting = create_session(%{status: "waiting", title: "Awaiting an answer"})
      compacting = create_session(%{status: "compacting", title: "Compacting"})

      conn = get(conn, "/api/drain")

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)

      assert body["safe_to_restart"] == false
      assert body["state"] == "ok"
      assert body["sessions"]["active"] == 3
      assert body["sessions"]["running"] == 1
      assert body["sessions"]["waiting"] == 1
      assert body["sessions"]["compacting"] == 1

      ids = Enum.map(body["sessions"]["items"], & &1["id"])
      assert running.id in ids
      assert waiting.id in ids
      assert compacting.id in ids

      # Titles, not just counts — the operator has to be able to decide.
      titles = Enum.map(body["sessions"]["items"], & &1["title"])
      assert "Deploy the thing" in titles
    end

    test "refuses on a non-terminal job even with no active session", %{conn: conn} do
      {:ok, job} =
        Jobs.create_job(%{
          directory: "/tmp/drain-test",
          runner_node: @this_node,
          command: "sleep 600",
          label: "big download"
        })

      conn = get(conn, "/api/drain")
      body = Jason.decode!(conn.resp_body)

      assert conn.status == 200
      assert body["safe_to_restart"] == false
      assert body["sessions"]["active"] == 0
      assert body["jobs"]["nonterminal"] == 1

      assert [%{"id" => id, "label" => "big download", "status" => "running"}] =
               body["jobs"]["items"]

      assert id == job.id
    end

    test "a terminal job does not hold a restart back", %{conn: conn} do
      {:ok, job} =
        Jobs.create_job(%{
          directory: "/tmp/drain-test",
          runner_node: @this_node,
          command: "echo hi"
        })

      {:ok, _} = Jobs.update_job(job, %{status: "succeeded"})

      conn = get(conn, "/api/drain")
      body = Jason.decode!(conn.resp_body)

      assert body["safe_to_restart"] == true
      assert body["jobs"]["nonterminal"] == 0
    end

    test "?ignore drops the caller's own session from the counts", %{conn: conn} do
      # The case this exists for: an agent-driven deploy runs INSIDE a
      # session on the host it's about to restart.
      self_session = create_session(%{status: "running", title: "the deploy itself"})
      other = create_session(%{status: "running", title: "someone else's work"})

      body = Jason.decode!(get(conn, "/api/drain?ignore=#{self_session.id}").resp_body)

      assert body["ignored"] == [self_session.id]
      assert body["safe_to_restart"] == false
      assert body["sessions"]["active"] == 1
      assert [%{"id" => id}] = body["sessions"]["items"]
      assert id == other.id
    end

    test "?ignore covering everything in flight reports safe", %{conn: conn} do
      a = create_session(%{status: "running", title: "a"})
      b = create_session(%{status: "waiting", title: "b"})

      body = Jason.decode!(get(conn, "/api/drain?ignore=#{a.id},#{b.id}").resp_body)

      assert body["safe_to_restart"] == true
      assert body["sessions"]["active"] == 0
    end

    test "a non-UUID ?ignore value is dropped, not handed to Ecto", %{conn: conn} do
      create_session(%{status: "running", title: "busy"})

      # A bare `not in ^["oops"]` would raise an Ecto cast error and turn a
      # typo into a bogus "unknown" state — the endpoint filters first.
      conn = get(conn, "/api/drain?ignore=oops,,%20")
      body = Jason.decode!(conn.resp_body)

      assert conn.status == 200
      assert body["state"] == "ok"
      assert body["ignored"] == []
      assert body["safe_to_restart"] == false
    end

    test "the response is greppable the way the deploy script parses it", %{conn: conn} do
      create_session(%{status: "running", title: "busy"})

      body = get(conn, "/api/drain").resp_body

      # deploy-orca-hub.sh parses /api/version with `grep -o`; the drain
      # check uses the same trick, so the boolean must sit at the top level
      # as a bare JSON literal.
      assert Regex.run(~r/"safe_to_restart":(true|false)/, body) == [
               ~s("safe_to_restart":false),
               "false"
             ]
    end
  end

  describe "agent mode with no hub reachable — the question is unanswerable" do
    setup do
      # An agent node with no connected hub: `OrcaHub.Mode.hub_node/0`
      # raises, so `HubRPC.call/3` can't answer. This is the real failure
      # mode on mini/gb10 when the hub is down or not yet clustered.
      Application.put_env(:orca_hub, :mode, :agent)
      :ok
    end

    test "returns 503 unknown, never a green light", %{conn: conn} do
      conn = get(conn, "/api/drain")

      assert conn.status == 503
      assert ["application/json" <> _] = get_resp_header(conn, "content-type")

      body = Jason.decode!(conn.resp_body)
      assert body["safe_to_restart"] == false
      assert body["state"] == "unknown"
      assert body["reason"] =~ "hub"
      # No counts to report — and crucially no zeroes that could read as
      # "all clear".
      refute Map.has_key?(body, "sessions")
      refute Map.has_key?(body, "jobs")
    end

    test "even a genuinely idle node reports unknown rather than safe", %{conn: conn} do
      # Nothing in flight anywhere — but we still can't SEE that, so the
      # answer stays unknown.
      body = Jason.decode!(get(conn, "/api/drain").resp_body)

      assert body["state"] == "unknown"
      assert body["safe_to_restart"] == false
    end

    test "the path is allow-listed through the agent-mode gate", %{conn: conn} do
      conn = get(conn, "/api/drain")

      # Not the gate's plain-text 404 — it reached `drain/2`.
      refute conn.status == 404
      refute conn.resp_body == "not found"
    end
  end
end
