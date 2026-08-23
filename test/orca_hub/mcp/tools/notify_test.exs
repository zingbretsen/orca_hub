defmodule OrcaHub.MCP.Tools.NotifyTest do
  # async: false — tests set the global :gotify_token/:gotify_req_options app env.
  use ExUnit.Case, async: false

  alias OrcaHub.MCP.Tools.Notify

  @stub OrcaHub.MCP.Tools.NotifyStub

  setup do
    Application.put_env(:orca_hub, :gotify_token, "test-token")
    Application.put_env(:orca_hub, :gotify_url, "https://gotify.example.com")
    Application.put_env(:orca_hub, :gotify_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.delete_env(:orca_hub, :gotify_token)
      Application.delete_env(:orca_hub, :gotify_url)
      Application.delete_env(:orca_hub, :gotify_req_options)
    end)

    :ok
  end

  describe "list/0" do
    test "exposes exactly send_notification" do
      names = Notify.list() |> Enum.map(& &1["name"])
      assert names == ["send_notification"]
    end

    test "requires only message" do
      [tool] = Notify.list()
      assert tool["inputSchema"]["required"] == ["message"]
    end
  end

  describe "call/3 validation" do
    test "rejects a missing message" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               Notify.call("send_notification", %{}, %{})

      assert msg =~ "message"
    end

    test "rejects an empty message" do
      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               Notify.call("send_notification", %{"message" => "   "}, %{})

      assert msg =~ "message"
    end
  end

  describe "call/3 without a configured token" do
    test "fails clearly" do
      Application.delete_env(:orca_hub, :gotify_token)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               Notify.call("send_notification", %{"message" => "hello"}, %{})

      assert msg =~ "GOTIFY_TOKEN"
    end
  end

  describe "call/3 against Gotify" do
    test "sends a notification with defaults" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert conn.request_path == "/message"
        assert conn.query_params["token"] == "test-token"
        assert body == %{"title" => "OrcaHub", "message" => "hello", "priority" => 5}

        Req.Test.json(conn, %{"id" => 1})
      end)

      result = Notify.call("send_notification", %{"message" => "hello"}, %{})

      assert %{"isError" => false, "content" => [%{"type" => "text", "text" => text}]} =
               result

      assert text =~ "Notification sent: %{\"id\" => 1}"
    end

    test "passes through title and priority" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body == %{"title" => "Alert", "message" => "urgent thing", "priority" => 9}

        Req.Test.json(conn, %{"id" => 2})
      end)

      result =
        Notify.call(
          "send_notification",
          %{"message" => "urgent thing", "title" => "Alert", "priority" => 9},
          %{}
        )

      assert %{"isError" => false, "content" => [%{"type" => "text", "text" => text}]} =
               result

      assert text =~ "Notification sent: %{\"id\" => 2}"
    end

    test "markdown adds client::display extras" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["extras"] == %{
                 "client::display" => %{"contentType" => "text/markdown"}
               }

        Req.Test.json(conn, %{"id" => 3})
      end)

      result =
        Notify.call(
          "send_notification",
          %{"message" => "**hi**", "markdown" => true},
          %{}
        )

      assert %{"isError" => false, "content" => [%{"type" => "text", "text" => text}]} =
               result

      assert text =~ "Notification sent: %{\"id\" => 3}"
    end

    test "click_url adds client::notification extras" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)

        assert body["extras"] == %{
                 "client::notification" => %{"click" => %{"url" => "https://orca.example.com"}}
               }

        Req.Test.json(conn, %{"id" => 4})
      end)

      result =
        Notify.call(
          "send_notification",
          %{"message" => "click me", "click_url" => "https://orca.example.com"},
          %{}
        )

      assert %{"isError" => false, "content" => [%{"type" => "text", "text" => text}]} =
               result

      assert text =~ "Notification sent: %{\"id\" => 4}"
    end

    test "surfaces a non-200 response as an error" do
      Req.Test.stub(@stub, fn conn ->
        conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{"error" => "unauthorized"})
      end)

      assert %{"isError" => true, "content" => [%{"text" => msg}]} =
               Notify.call("send_notification", %{"message" => "hello"}, %{})

      assert msg =~ "401"
    end
  end

  describe "OrcaHub.Notify.deliver/1 directly" do
    test "accepts atom keys" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["message"] == "atom keys work"

        Req.Test.json(conn, %{"id" => 5})
      end)

      assert {:ok, _summary} =
               OrcaHub.Notify.deliver(%{message: "atom keys work"})
    end
  end
end
