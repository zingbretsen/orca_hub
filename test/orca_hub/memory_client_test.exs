defmodule OrcaHub.MemoryClientTest do
  # async: false — tests set the global :memory_service_url/:memory_service_token/
  # :memory_service_req_options app env (see config/test.exs, which disables the
  # feature by default).
  use ExUnit.Case, async: false

  alias OrcaHub.MemoryClient

  @stub OrcaHub.MemoryClientStub

  setup do
    Application.put_env(:orca_hub, :memory_service_url, "https://memory.example.com")
    Application.put_env(:orca_hub, :memory_service_token, "test-token")
    Application.put_env(:orca_hub, :memory_service_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.put_env(:orca_hub, :memory_service_url, nil)
      Application.put_env(:orca_hub, :memory_service_token, nil)
      Application.delete_env(:orca_hub, :memory_service_req_options)
    end)

    :ok
  end

  describe "enabled?/0" do
    test "true when url and token are both set" do
      assert MemoryClient.enabled?()
    end

    test "false when url is missing" do
      Application.put_env(:orca_hub, :memory_service_url, nil)
      refute MemoryClient.enabled?()
    end

    test "false when token is missing" do
      Application.put_env(:orca_hub, :memory_service_token, nil)
      refute MemoryClient.enabled?()
    end
  end

  describe "disabled behavior" do
    setup do
      Application.put_env(:orca_hub, :memory_service_url, nil)
      :ok
    end

    test "every write/read function returns {:error, :disabled} without an HTTP call" do
      assert {:error, :disabled} = MemoryClient.remember(%{"text" => "x", "kind" => "fact"})
      assert {:error, :disabled} = MemoryClient.search(%{"query" => "x"})
      assert {:error, :disabled} = MemoryClient.get("id-1")
      assert {:error, :disabled} = MemoryClient.update("id-1", %{"text" => "y"})
      assert {:error, :disabled} = MemoryClient.retire("id-1", "stale")
      assert {:error, :disabled} = MemoryClient.verify("id-1")
      assert {:error, :disabled} = MemoryClient.merge(["a", "b"], %{"text" => "z"})
      assert {:error, :disabled} = MemoryClient.list(%{})
    end

    test "context_block/3 returns {:ok, nil} instead of an error" do
      assert {:ok, nil} = MemoryClient.context_block("proj-slug", "prompt")
    end
  end

  describe "remember/1" do
    test "POSTs the document and returns the memory + near_duplicates" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "POST"
        assert conn.request_path == "/v1/memories"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]

        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["text"] == "always use bin/test"
        assert body["kind"] == "procedure"

        conn
        |> Plug.Conn.put_status(201)
        |> Req.Test.json(%{
          "memory" => %{"id" => "mem-1", "text" => body["text"]},
          "near_duplicates" => []
        })
      end)

      assert {:ok, %{"memory" => %{"id" => "mem-1"}, "near_duplicates" => []}} =
               MemoryClient.remember(%{"text" => "always use bin/test", "kind" => "procedure"})
    end

    test "surfaces a non-2xx as an error tuple" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => %{"code" => "invalid"}})
      end)

      assert {:error, {:http_error, 422, %{"error" => %{"code" => "invalid"}}}} =
               MemoryClient.remember(%{"text" => "", "kind" => "fact"})
    end
  end

  describe "search/1" do
    test "POSTs to /v1/memories/search and returns hits" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/search"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw)["query"] == "postgres provisioning"

        Req.Test.json(conn, %{"hits" => [%{"memory" => %{"id" => "mem-2"}, "score" => 0.9}]})
      end)

      assert {:ok, %{"hits" => [%{"memory" => %{"id" => "mem-2"}}]}} =
               MemoryClient.search(%{"query" => "postgres provisioning"})
    end
  end

  describe "get/1" do
    test "GETs /v1/memories/:id" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/memories/mem-3"
        Req.Test.json(conn, %{"memory" => %{"id" => "mem-3"}})
      end)

      assert {:ok, %{"memory" => %{"id" => "mem-3"}}} = MemoryClient.get("mem-3")
    end
  end

  describe "update/2" do
    test "PATCHes /v1/memories/:id with the given fields" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/v1/memories/mem-4"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"importance" => 5}

        Req.Test.json(conn, %{"memory" => %{"id" => "mem-4", "importance" => 5}})
      end)

      assert {:ok, %{"memory" => %{"importance" => 5}}} =
               MemoryClient.update("mem-4", %{"importance" => 5})
    end
  end

  describe "retire/3" do
    test "POSTs reason, omitting superseded_by when absent" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/mem-5/retire"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"reason" => "no longer true"}

        Req.Test.json(conn, %{"memory" => %{"id" => "mem-5", "status" => "retired"}})
      end)

      assert {:ok, _} = MemoryClient.retire("mem-5", "no longer true")
    end

    test "includes superseded_by when given" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"reason" => "merged", "superseded_by" => "mem-6"}

        Req.Test.json(conn, %{"memory" => %{"id" => "mem-5", "status" => "retired"}})
      end)

      assert {:ok, _} = MemoryClient.retire("mem-5", "merged", superseded_by: "mem-6")
    end
  end

  describe "verify/1" do
    test "POSTs /v1/memories/:id/verify" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/mem-7/verify"
        Req.Test.json(conn, %{"memory" => %{"id" => "mem-7"}})
      end)

      assert {:ok, %{"memory" => %{"id" => "mem-7"}}} = MemoryClient.verify("mem-7")
    end
  end

  describe "verify_batch/1" do
    test "POSTs /v1/memories/verify with the ids" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/verify"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(raw) == %{"ids" => ["mem-1", "mem-2"]}

        Req.Test.json(conn, %{"verified" => ["mem-1", "mem-2"]})
      end)

      assert {:ok, %{"verified" => ["mem-1", "mem-2"]}} =
               MemoryClient.verify_batch(["mem-1", "mem-2"])
    end
  end

  describe "flag/2" do
    test "PATCHes review_status/review_note and reports mechanism: review_status" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "PATCH"
        assert conn.request_path == "/v1/memories/mem-1"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(raw) == %{
                 "review_status" => "pending",
                 "review_note" => "contradicts mem-2"
               }

        Req.Test.json(conn, %{"memory" => %{"id" => "mem-1", "review_status" => "pending"}})
      end)

      assert {:ok, %{"memory" => %{"id" => "mem-1"}, "mechanism" => "review_status"}} =
               MemoryClient.flag("mem-1", "contradicts mem-2")
    end

    test "falls back to a needs-review tag on a 422, preserving existing tags" do
      Req.Test.stub(@stub, fn
        %{method: "PATCH", request_path: "/v1/memories/mem-1"} = conn ->
          case Plug.Conn.read_body(conn) do
            {:ok, raw, conn} ->
              body = Jason.decode!(raw)

              cond do
                Map.has_key?(body, "review_status") ->
                  conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => "unsupported"})

                Map.has_key?(body, "tags") ->
                  assert body["tags"] == ["existing", "needs-review"]
                  Req.Test.json(conn, %{"memory" => %{"id" => "mem-1", "tags" => body["tags"]}})
              end
          end

        %{method: "GET", request_path: "/v1/memories/mem-1"} = conn ->
          Req.Test.json(conn, %{"id" => "mem-1", "tags" => ["existing"]})
      end)

      assert {:ok,
              %{
                "memory" => %{"tags" => ["existing", "needs-review"]},
                "mechanism" => "tags_fallback"
              }} =
               MemoryClient.flag("mem-1", "importance looks inflated")
    end

    test "truncates review_note to 500 chars before sending" do
      long_reason = String.duplicate("x", 600)

      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert String.length(body["review_note"]) == 500
        assert body["review_note"] == String.duplicate("x", 500)
        Req.Test.json(conn, %{"memory" => %{"id" => "mem-1"}})
      end)

      assert {:ok, _} = MemoryClient.flag("mem-1", long_reason)
    end
  end

  describe "duplicates/1" do
    test "GETs /v1/memories/duplicates with query params" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/memories/duplicates"
        assert conn.query_params["project_slug"] == "-home-zach-orca-hub"
        assert conn.query_params["threshold"] == "0.85"

        Req.Test.json(conn, %{
          "groups" => [%{"memories" => [%{"id" => "a"}, %{"id" => "b"}], "max_score" => 0.9}]
        })
      end)

      assert {:ok, %{"groups" => [%{"max_score" => 0.9}]}} =
               MemoryClient.duplicates(%{
                 "project_slug" => "-home-zach-orca-hub",
                 "threshold" => 0.85
               })
    end

    test "a 404 (the service may not implement this endpoint yet) comes back as an ordinary error" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not found"})
      end)

      assert {:error, {:http_error, 404, _body}} = MemoryClient.duplicates(%{})
    end

    test "never retries a 5xx — this endpoint's own scan is too expensive to risk amplifying" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@stub, fn conn ->
        Agent.update(counter, &(&1 + 1))
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      assert {:error, {:http_error, 500, _body}} = MemoryClient.duplicates(%{})
      assert Agent.get(counter, & &1) == 1
    end
  end

  describe "merge/2" do
    test "POSTs source_ids merged with the given attrs" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/merge"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)

        assert Jason.decode!(raw) == %{
                 "source_ids" => ["a", "b"],
                 "text" => "combined",
                 "kind" => "fact"
               }

        Req.Test.json(conn, %{"memory" => %{"id" => "mem-8"}, "supersedes" => ["a", "b"]})
      end)

      assert {:ok, %{"memory" => %{"id" => "mem-8"}}} =
               MemoryClient.merge(["a", "b"], %{"text" => "combined", "kind" => "fact"})
    end
  end

  describe "list/1" do
    test "GETs /v1/memories with query params" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/memories"
        assert conn.query_params["kind"] == "decision"

        Req.Test.json(conn, %{"memories" => []})
      end)

      assert {:ok, %{"memories" => []}} = MemoryClient.list(%{"kind" => "decision"})
    end
  end

  describe "tags/1" do
    test "GETs /v1/tags with query params" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/tags"
        assert conn.query_params["project_slug"] == "-home-zach-orca-hub"

        Req.Test.json(conn, [%{"tag" => "trunk-based-dev", "count" => 4}])
      end)

      assert {:ok, [%{"tag" => "trunk-based-dev", "count" => 4}]} =
               MemoryClient.tags(%{"project_slug" => "-home-zach-orca-hub"})
    end

    test "a 404 (the service may not implement this endpoint yet) comes back as an ordinary error" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "not found"})
      end)

      assert {:error, {:http_error, 404, _body}} = MemoryClient.tags(%{"project_slug" => "x"})
    end
  end

  describe "retry policy" do
    test "a 500 on a mutating (POST) call is returned once, never auto-retried" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@stub, fn conn ->
        Agent.update(counter, &(&1 + 1))
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      assert {:error, {:http_error, 500, _body}} =
               MemoryClient.remember(%{"text" => "x", "kind" => "fact"})

      assert Agent.get(counter, & &1) == 1
    end

    test "a 500 on a PATCH call is returned once, never auto-retried" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@stub, fn conn ->
        Agent.update(counter, &(&1 + 1))
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      assert {:error, {:http_error, 500, _body}} =
               MemoryClient.update("mem-1", %{"importance" => 4})

      assert Agent.get(counter, & &1) == 1
    end

    test "a 500 on an ordinary GET call is capped at one retry, not Req's default 3" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      Req.Test.stub(@stub, fn conn ->
        Agent.update(counter, &(&1 + 1))
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      assert {:error, {:http_error, 500, _body}} = MemoryClient.list(%{})
      assert Agent.get(counter, & &1) == 2
    end
  end

  describe "context_block/3" do
    test "returns the rendered block on success" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/context"
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["project_slug"] == "-home-zach-orca-hub"
        assert body["budget_tokens"] == 3000

        Req.Test.json(conn, %{
          "block" => "# Recalled memories\n- [fact] ...",
          "memory_ids" => ["mem-9"],
          "pinned_count" => 0,
          "recalled_count" => 1
        })
      end)

      assert {:ok, "# Recalled memories\n- [fact] ..."} =
               MemoryClient.context_block("-home-zach-orca-hub", "some prompt")
    end

    test "collapses an HTTP error into {:ok, nil} rather than blocking a spawn" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => "boom"}})
      end)

      assert {:ok, nil} = MemoryClient.context_block("-home-zach-orca-hub", "some prompt")
    end

    test "collapses a transport failure into {:ok, nil}" do
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      assert {:ok, nil} = MemoryClient.context_block("-home-zach-orca-hub", "some prompt")
    end

    test "passes through opts for budget/include flags" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["budget_tokens"] == 500
        assert body["include_global"] == false

        Req.Test.json(conn, %{"block" => "x"})
      end)

      assert {:ok, "x"} =
               MemoryClient.context_block("slug", "prompt",
                 budget_tokens: 500,
                 include_global: false
               )
    end
  end

  describe "context/3" do
    test "returns the full response — block, memory_ids, pinned_count, recalled_count" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/v1/memories/context"

        Req.Test.json(conn, %{
          "block" => "# Recalled memories\n- [fact] ...",
          "memory_ids" => ["mem-9", "mem-10"],
          "pinned_count" => 1,
          "recalled_count" => 1
        })
      end)

      assert {:ok,
              %{
                "block" => "# Recalled memories\n- [fact] ...",
                "memory_ids" => ["mem-9", "mem-10"],
                "pinned_count" => 1,
                "recalled_count" => 1
              }} = MemoryClient.context("-home-zach-orca-hub", "some prompt")
    end

    test "defaults memory_ids to [] when the service response omits it" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"block" => "- a fact", "pinned_count" => 0, "recalled_count" => 1})
      end)

      assert {:ok, %{"memory_ids" => []}} = MemoryClient.context("slug", "prompt")
    end

    test "collapses an HTTP error into {:ok, nil} rather than blocking a spawn" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => %{"message" => "boom"}})
      end)

      assert {:ok, nil} = MemoryClient.context("-home-zach-orca-hub", "some prompt")
    end

    test "returns {:ok, nil} when the service is disabled, no HTTP call" do
      Application.put_env(:orca_hub, :memory_service_url, nil)
      assert {:ok, nil} = MemoryClient.context("slug", "prompt")
    end

    test "passes through the \"memories\" array when the service includes it (memory-service c932074)" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{
          "block" => "# Recalled memories\n- [fact] ...",
          "memory_ids" => ["mem-9", "mem-10"],
          "memories" => [
            %{
              "id" => "mem-9",
              "hook" => "first hook",
              "kind" => "fact",
              "pinned" => true,
              "review_status" => "approved"
            },
            %{
              "id" => "mem-10",
              "hook" => "second hook",
              "kind" => "preference",
              "pinned" => false,
              "review_status" => "pending"
            }
          ],
          "pinned_count" => 1,
          "recalled_count" => 1
        })
      end)

      assert {:ok, %{"memories" => [%{"id" => "mem-9"}, %{"id" => "mem-10"}]}} =
               MemoryClient.context("slug", "prompt")
    end

    test "\"memories\" is nil when the service response omits it (older service)" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"block" => "- a fact", "memory_ids" => ["mem-1"]})
      end)

      assert {:ok, %{"memories" => nil}} = MemoryClient.context("slug", "prompt")
    end
  end

  describe "list_created_by_session/2" do
    test "merges direct session_id hits with source.session_id-matched extraction hits, deduped" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.method == "GET"
        assert conn.request_path == "/v1/memories"

        case conn.query_params do
          %{"session_id" => "sess-1"} ->
            Req.Test.json(conn, %{
              "memories" => [
                %{"id" => "mem-1", "hook" => "direct remember", "created_by" => "agent"}
              ]
            })

          %{"project_slug" => "-home-zach-orca-hub"} ->
            Req.Test.json(conn, %{
              "memories" => [
                %{
                  "id" => "mem-2",
                  "hook" => "extracted fact",
                  "created_by" => "extraction",
                  "source" => %{"session_id" => "sess-1"}
                },
                %{
                  "id" => "mem-3",
                  "hook" => "someone else's extraction",
                  "created_by" => "extraction",
                  "source" => %{"session_id" => "other-session"}
                },
                # Duplicate of the direct hit (e.g. this session's own
                # remember also surfaced in the project-wide sweep) — must
                # not be double-counted.
                %{"id" => "mem-1", "hook" => "direct remember", "created_by" => "agent"}
              ]
            })
        end
      end)

      assert {:ok, %{memories: memories, truncated: false}} =
               MemoryClient.list_created_by_session("sess-1", "-home-zach-orca-hub")

      assert memories |> Enum.map(& &1["id"]) |> Enum.sort() == ["mem-1", "mem-2"]
    end

    test "caps at 50 and reports truncated: true" do
      direct = for i <- 1..30, do: %{"id" => "d-#{i}", "hook" => "hook #{i}"}

      extracted =
        for i <- 1..30 do
          %{
            "id" => "e-#{i}",
            "hook" => "hook #{i}",
            "created_by" => "extraction",
            "source" => %{"session_id" => "sess-1"}
          }
        end

      Req.Test.stub(@stub, fn conn ->
        case conn.query_params do
          %{"session_id" => "sess-1"} -> Req.Test.json(conn, %{"memories" => direct})
          %{"project_slug" => _} -> Req.Test.json(conn, %{"memories" => extracted})
        end
      end)

      assert {:ok, %{memories: memories, truncated: true}} =
               MemoryClient.list_created_by_session("sess-1", "slug")

      assert length(memories) == 50
    end

    test "an HTTP error from either leg fails the whole call rather than returning a partial list" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
      end)

      assert {:error, {:http_error, 500, _body}} =
               MemoryClient.list_created_by_session("sess-1", "slug")
    end

    test "returns {:error, :disabled} when the service isn't configured, no HTTP call" do
      Application.put_env(:orca_hub, :memory_service_url, nil)

      assert {:error, :disabled} = MemoryClient.list_created_by_session("sess-1", "slug")
    end
  end
end
