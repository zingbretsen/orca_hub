defmodule OrcaHubWeb.SessionEventsChannelTest do
  @moduledoc """
  `/api/v1/socket` + the `session_events` channel — orca-watch DESIGN.md D6
  (the Android app takes turn-end events from the hub, not Gotify) and R12
  (the payload is a contract: what the push omits, the client can never
  recover).

  Two halves, both asserted here:

    * **connect** — the token goes through exactly the path the bearer plug
      uses (`ApiTokens.authenticate/1`), so revoked/expired/unknown and
      wrong-scope are all refused at the handshake, never accepted then
      refused at join;
    * **join** — an unpinned token gets `session_events:all`, a
      session-pinned token gets ONLY its own session's topic.
  """
  # async: false — the socket's connect/3 hits the Repo, and these tests
  # broadcast on the app-wide endpoint.
  use OrcaHub.DataCase, async: false

  import Phoenix.ChannelTest

  alias OrcaHub.{ApiTokens, SessionEvents, Sessions}
  alias OrcaHubWeb.{ApiSocket, SessionEventsChannel}

  @endpoint OrcaHubWeb.Endpoint

  setup do
    dir = Path.join(System.tmp_dir!(), "session_events_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, session} = Sessions.create_session(%{directory: dir, status: "idle", title: "the one"})

    {:ok, dir: dir, session: session}
  end

  defp token(attrs) do
    {:ok, %{token: token, secret: secret}} =
      ApiTokens.create_token(
        Map.merge(%{"name" => "t-#{System.unique_integer([:positive])}"}, attrs)
      )

    {token, secret}
  end

  defp read_token, do: token(%{"scopes" => ["sessions:read"]})

  describe "connect/3" do
    test "accepts a valid sessions:read token passed as the `token` param" do
      {token, secret} = read_token()

      assert {:ok, socket} = connect(ApiSocket, %{"token" => secret})
      assert socket.assigns.api_token_id == token.id
      assert socket.assigns.pinned_session_id == nil
      assert ApiSocket.id(socket) == "api_token:#{token.id}"
    end

    test "touches last_used_at, like the bearer plug does" do
      {token, secret} = read_token()
      assert is_nil(token.last_used_at)

      assert {:ok, _socket} = connect(ApiSocket, %{"token" => secret})

      assert %{last_used_at: %DateTime{}} = Repo.get!(OrcaHub.ApiTokens.ApiToken, token.id)
    end

    test "rejects a missing token param" do
      assert :error = connect(ApiSocket, %{})
      assert :error = connect(ApiSocket, %{"token" => nil})
      assert :error = connect(ApiSocket, %{"token" => ""})
    end

    test "rejects an unknown token" do
      assert :error = connect(ApiSocket, %{"token" => "orca_nope"})
    end

    test "rejects a revoked token" do
      {token, secret} = read_token()
      assert {:ok, _} = connect(ApiSocket, %{"token" => secret})

      {:ok, _} = ApiTokens.revoke_token(token.id)

      assert :error = connect(ApiSocket, %{"token" => secret})
    end

    test "rejects an expired token" do
      past = DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
      {_token, secret} = token(%{"scopes" => ["sessions:read"], "expires_at" => past})

      assert :error = connect(ApiSocket, %{"token" => secret})
    end

    test "rejects a valid token that lacks the sessions:read scope" do
      {_token, secret} = token(%{"scopes" => ["runs:create"]})

      assert :error = connect(ApiSocket, %{"token" => secret})
    end

    test "rejects the legacy static ORCA_API_TOKEN — this surface is scoped-only" do
      Application.put_env(:orca_hub, :api_token, "legacy-static-token")
      on_exit(fn -> Application.delete_env(:orca_hub, :api_token) end)

      assert :error = connect(ApiSocket, %{"token" => "legacy-static-token"})
    end

    test "accepts a session-pinned token and remembers its pin", %{session: session} do
      {_token, secret} =
        token(%{"scopes" => ["sessions:read"], "session_id" => session.id})

      assert {:ok, socket} = connect(ApiSocket, %{"token" => secret})
      assert socket.assigns.pinned_session_id == session.id
    end
  end

  describe "revocation disconnects a live socket" do
    test "broadcasts \"disconnect\" on the socket's id topic" do
      {token, _secret} = read_token()

      @endpoint.subscribe("api_token:#{token.id}")
      {:ok, _} = ApiTokens.revoke_token(token.id)

      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end
  end

  describe "join/3" do
    test "an unpinned token joins session_events:all" do
      {_token, secret} = read_token()
      {:ok, socket} = connect(ApiSocket, %{"token" => secret})

      assert {:ok, _reply, _socket} =
               subscribe_and_join(socket, SessionEventsChannel, "session_events:all")
    end

    test "an unpinned token may also join a single session's topic", %{session: session} do
      {_token, secret} = read_token()
      {:ok, socket} = connect(ApiSocket, %{"token" => secret})

      assert {:ok, _reply, _socket} =
               subscribe_and_join(
                 socket,
                 SessionEventsChannel,
                 SessionEvents.session_topic(session.id)
               )
    end

    test "a pinned token cannot join :all, but can join its own session", %{session: session} do
      {_token, secret} = token(%{"scopes" => ["sessions:read"], "session_id" => session.id})
      {:ok, socket} = connect(ApiSocket, %{"token" => secret})

      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(socket, SessionEventsChannel, "session_events:all")

      assert {:ok, _reply, _socket} =
               subscribe_and_join(
                 socket,
                 SessionEventsChannel,
                 SessionEvents.session_topic(session.id)
               )
    end

    test "a pinned token cannot join someone else's session", %{dir: dir, session: session} do
      {:ok, other} = Sessions.create_session(%{directory: dir, status: "idle", title: "other"})

      {_token, secret} = token(%{"scopes" => ["sessions:read"], "session_id" => session.id})
      {:ok, socket} = connect(ApiSocket, %{"token" => secret})

      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(
                 socket,
                 SessionEventsChannel,
                 SessionEvents.session_topic(other.id)
               )
    end

    test "a non-UUID session topic is refused rather than silently subscribed" do
      {_token, secret} = read_token()
      {:ok, socket} = connect(ApiSocket, %{"token" => secret})

      assert {:error, %{reason: "forbidden"}} =
               subscribe_and_join(socket, SessionEventsChannel, "session_events:not-a-uuid")
    end
  end

  describe "pushes and replies" do
    setup do
      {_token, secret} = read_token()
      {:ok, socket} = connect(ApiSocket, %{"token" => secret})

      {:ok, _reply, joined} =
        subscribe_and_join(socket, SessionEventsChannel, "session_events:all")

      {:ok, socket: joined}
    end

    test "ping replies pong", %{socket: socket} do
      ref = push(socket, "ping", %{})
      assert_reply ref, :ok, %{"pong" => true}
    end

    test "an unknown event is refused, not a crash", %{socket: socket} do
      ref = push(socket, "nonsense", %{})
      assert_reply ref, :error, %{reason: "unknown event"}
    end

    test "a SessionEvents.turn_end broadcast reaches the client with all five fields",
         %{session: session} do
      {:ok, _payload} =
        SessionEvents.turn_end(%{
          session_id: session.id,
          session_title: "the worker",
          status: "idle",
          excerpt: "All three migrations applied cleanly."
        })

      assert_push "turn_end", payload

      assert %{
               session_id: session_id,
               session_title: "the worker",
               status: "idle",
               excerpt: "All three migrations applied cleanly.",
               occurred_at: occurred_at
             } = payload

      assert session_id == session.id
      assert {:ok, _, _} = DateTime.from_iso8601(occurred_at)
    end
  end

  describe "no backlog on join" do
    test "a turn end that happened before the join is not replayed", %{session: session} do
      # Broadcast FIRST, then join: the client reconciles what it missed via
      # /sessions/recent?since=<high-water>, not via replay.
      {:ok, _} =
        SessionEvents.turn_end(%{
          session_id: session.id,
          session_title: "earlier",
          status: "idle"
        })

      {_token, secret} = read_token()
      {:ok, socket} = connect(ApiSocket, %{"token" => secret})

      {:ok, _reply, _joined} =
        subscribe_and_join(socket, SessionEventsChannel, "session_events:all")

      refute_push "turn_end", _payload, 200
    end
  end

  describe "per-session topic" do
    test "receives its own session's turn end and not another's", %{dir: dir, session: session} do
      {:ok, other} = Sessions.create_session(%{directory: dir, status: "idle", title: "other"})

      {_token, secret} = token(%{"scopes" => ["sessions:read"], "session_id" => session.id})
      {:ok, socket} = connect(ApiSocket, %{"token" => secret})

      {:ok, _reply, _joined} =
        subscribe_and_join(socket, SessionEventsChannel, SessionEvents.session_topic(session.id))

      {:ok, _} =
        SessionEvents.turn_end(%{session_id: other.id, session_title: "other", status: "idle"})

      refute_push "turn_end", _payload, 200

      {:ok, _} =
        SessionEvents.turn_end(%{session_id: session.id, session_title: "mine", status: "error"})

      assert_push "turn_end", %{session_title: "mine", status: "error"}
    end
  end
end
