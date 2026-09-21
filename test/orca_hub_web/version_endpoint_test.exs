defmodule OrcaHubWeb.VersionEndpointTest do
  @moduledoc """
  GET /api/version is handled directly in the Endpoint (like /healthz),
  ahead of the Router pipeline — so it's reachable with no session/auth
  plugs applied. See lib/orca_hub_web/endpoint.ex.
  """

  use OrcaHubWeb.ConnCase, async: false

  alias OrcaHub.Cluster.CodeStamp

  setup do
    CodeStamp.clear()
    on_exit(&CodeStamp.clear/0)
    :ok
  end

  test "GET /api/version returns sha and built_at with no auth", %{conn: conn} do
    conn = get(conn, "/api/version")

    assert conn.status == 200
    assert ["application/json" <> _] = get_resp_header(conn, "content-type")

    assert %{"sha" => sha, "built_at" => built_at} = Jason.decode!(conn.resp_body)
    assert is_binary(sha) and sha != ""
    assert {:ok, _, _} = DateTime.from_iso8601(built_at)
  end

  describe "code_sha — the LIVE code, distinct from the build" do
    test "with no generation applied it is null and says so, never the build sha", %{conn: conn} do
      body = conn |> get("/api/version") |> response(200) |> Jason.decode!()

      assert body["code_sha"] == nil
      assert body["code"]["source"] == "image"
      assert body["code"]["detail"] =~ "no code generation has been applied"
      # The failure mode this field exists to prevent: reading "running its
      # image" as "running the build sha".
      refute body["code"]["base_sha"] == body["sha"]
    end

    test "once a generation is applied it reports that generation, not the image", %{conn: conn} do
      {:ok, _} =
        CodeStamp.record(node(), %{
          generation_id: "gen-42",
          base_sha: "0badc0ffee11",
          dirty: true,
          module_count: 277,
          modules_loaded: 9,
          apply_status: "reconciled"
        })

      body = conn |> get("/api/version") |> response(200) |> Jason.decode!()

      assert body["code_sha"] == "0badc0ffee11"
      assert body["code"]["source"] == "generation"
      assert body["code"]["generation_id"] == "gen-42"
      assert body["code"]["dirty"] == true
      assert body["code"]["module_count"] == 277
      assert body["code"]["modules_loaded"] == 9
      assert body["code"]["apply_status"] == "reconciled"
      assert {:ok, _, _} = DateTime.from_iso8601(body["code"]["applied_at"])
      assert {:ok, _, _} = DateTime.from_iso8601(body["code"]["verified_at"])

      # The build sha is untouched by a hot load — that is the whole reason
      # both fields have to exist.
      assert body["sha"] == OrcaHub.BuildInfo.sha()
      refute body["sha"] == body["code_sha"]
    end
  end

  describe "the deploy scripts' parser" do
    # deploy-orca-hub.sh and verify-orca-deploy.sh both read the build sha
    # with `grep -o '"sha":"[^"]*"' | cut -d'"' -f4`. Adding a key whose name
    # ENDS in `sha` is safe only while none of them is preceded by a quote —
    # `"code_sha"` and `"base_sha"` are, `"sha"` alone is not. This test is
    # the guard on that, because breaking it silently breaks every deploy
    # verification on all six instances.
    test "grep -o '\"sha\":\"...\"' still matches exactly the build sha", %{conn: conn} do
      {:ok, _} =
        CodeStamp.record(node(), %{
          generation_id: "gen-99",
          base_sha: "aaaabbbbcccc",
          dirty: false,
          module_count: 1,
          modules_loaded: 1,
          apply_status: "in_sync"
        })

      body = conn |> get("/api/version") |> response(200)

      matches = Regex.scan(~r/"sha":"[^"]*"/, body) |> List.flatten()

      assert matches == [~s("sha":"#{OrcaHub.BuildInfo.sha()}")]
    end
  end
end
