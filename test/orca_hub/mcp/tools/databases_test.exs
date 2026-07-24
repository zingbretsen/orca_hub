defmodule OrcaHub.MCP.Tools.DatabasesTest do
  # async: false — tests set the global :pgprov_req_options/:pgprov_api_token app env.
  use ExUnit.Case, async: false

  alias OrcaHub.MCP.Tools.Databases

  @stub OrcaHub.MCP.Tools.DatabasesStub

  setup do
    Application.put_env(:orca_hub, :pgprov_api_token, "test-token")
    Application.put_env(:orca_hub, :pgprov_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.delete_env(:orca_hub, :pgprov_api_token)
      Application.delete_env(:orca_hub, :pgprov_req_options)
    end)

    :ok
  end

  describe "list/0" do
    test "exposes provision_database and list_databases" do
      names = Databases.list() |> Enum.map(& &1["name"])
      assert names == ["provision_database", "list_databases"]
    end

    test "provision_database requires app but not environments" do
      [provision_tool, _list_tool] = Databases.list()
      assert provision_tool["inputSchema"]["required"] == ["app"]
    end

    test "provision_database description tells callers deletion is human-only" do
      [provision_tool, _list_tool] = Databases.list()
      assert provision_tool["description"] =~ "human-only"

      assert provision_tool["description"] =~ "one-time" or
               provision_tool["description"] =~ "ONE-TIME"
    end

    test "neither tool is named drop_database or delete_database" do
      names = Databases.list() |> Enum.map(& &1["name"])
      refute "drop_database" in names
      refute "delete_database" in names
    end
  end

  describe "call/3 provision_database validation" do
    test "rejects a missing app" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               Databases.call("provision_database", %{}, %{})

      assert msg =~ "app is required"
    end

    test "rejects an invalid app name" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               Databases.call("provision_database", %{"app" => "My-App!"}, %{})

      assert msg =~ "lowercase"
    end

    test "rejects an environment outside dev/test/prod" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               Databases.call(
                 "provision_database",
                 %{"app" => "myapp", "environments" => ["staging"]},
                 %{}
               )

      assert msg =~ "subset"
    end
  end

  describe "call/3 without a configured token" do
    test "provision_database fails clearly" do
      Application.delete_env(:orca_hub, :pgprov_api_token)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               Databases.call("provision_database", %{"app" => "myapp"}, %{})

      assert msg =~ "PGPROV_API_TOKEN"
    end

    test "list_databases fails clearly" do
      Application.delete_env(:orca_hub, :pgprov_api_token)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               Databases.call("list_databases", %{}, %{})

      assert msg =~ "PGPROV_API_TOKEN"
    end
  end

  describe "call/3 provision_database against the API" do
    test "defaults environments to [\"dev\"] and returns results verbatim" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body == %{"app" => "myapp", "environments" => ["dev"]}
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]
        assert conn.request_path == "/api/provision"

        Req.Test.json(conn, %{
          "app" => "myapp",
          "results" => [
            %{
              "env" => "dev",
              "db" => "myapp_dev",
              "status" => "created",
              "user" => "myapp_dev",
              "password" => "secret",
              "dsn" => "postgresql://myapp_dev:secret@192.168.1.177:5432/myapp_dev"
            }
          ]
        })
      end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} =
               Databases.call("provision_database", %{"app" => "myapp"}, %{})

      decoded = Jason.decode!(text)
      assert decoded["app"] == "myapp"
      assert [%{"status" => "created", "dsn" => dsn}] = decoded["results"]
      assert dsn =~ "postgresql://"
    end

    test "normalizes app case and passes through requested environments" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body == %{"app" => "myapp", "environments" => ["dev", "prod"]}

        Req.Test.json(conn, %{"app" => "myapp", "results" => []})
      end)

      assert %{"isError" => false} =
               Databases.call(
                 "provision_database",
                 %{"app" => "MyApp", "environments" => ["dev", "prod"]},
                 %{}
               )
    end

    test "surfaces a non-200 response as an error" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"detail" => "unauthorized"})
      end)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               Databases.call("provision_database", %{"app" => "myapp"}, %{})

      assert msg =~ "401"
    end
  end

  describe "call/3 list_databases against the API" do
    test "returns the database list verbatim" do
      Req.Test.stub(@stub, fn conn ->
        assert conn.request_path == "/api/databases"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-token"]

        Req.Test.json(conn, %{
          "databases" => [
            %{
              "name" => "myapp_dev",
              "owner" => "myapp_dev",
              "size" => "7433 kB",
              "protected" => false
            }
          ]
        })
      end)

      assert %{"isError" => false, "content" => [%{"text" => text}]} =
               Databases.call("list_databases", %{}, %{})

      assert [%{"name" => "myapp_dev", "protected" => false}] = Jason.decode!(text)
    end
  end
end
