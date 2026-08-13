defmodule OrcaHub.EmailInbox.ImapClientTest do
  @moduledoc """
  Drives `ImapClient` against a scripted fake IMAP server on loopback.

  The point is the hand-rolled protocol plumbing: tagged-response framing and
  `{N}` literal reading, which is where a from-scratch client is most likely
  to be subtly wrong (and where a wrong answer would silently mangle the raw
  RFC822 source the whole security model is parsed from).
  """

  use OrcaHub.DataCase, async: true

  alias OrcaHub.EmailInbox.ImapClient
  alias OrcaHub.EmailInboxes

  @raw_message "From: zach@x.com\r\nSubject: hi\r\n\r\nbody line 1\r\nbody line 2\r\n"

  setup do
    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    acceptor = spawn_link(fn -> accept_loop(listen) end)

    on_exit(fn ->
      Process.unlink(acceptor)
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end)

    %{port: port}
  end

  defp connected(port) do
    {:ok, client} = ImapClient.connect("127.0.0.1", port, false)
    client
  end

  defp logged_in(port) do
    {:ok, client} = ImapClient.login(connected(port), "ops@example.com", "hunter2")
    client
  end

  test "logs in", %{port: port} do
    assert {:ok, _client} = ImapClient.login(connected(port), "ops@example.com", "hunter2")
  end

  test "reports a rejected login without echoing the credentials", %{port: port} do
    assert {:error, :login_failed} = ImapClient.login(connected(port), "ops@example.com", "wrong")
  end

  test "parses UIDVALIDITY, UIDNEXT and EXISTS out of SELECT", %{port: port} do
    assert {:ok, _client, mailbox} = ImapClient.select(logged_in(port), "INBOX")
    assert mailbox.uid_validity == 99
    assert mailbox.uid_next == 12
    assert mailbox.exists == 3
  end

  test "UID SEARCH filters out UIDs at or below the watermark", %{port: port} do
    # The fake server answers with 5, 8 and 11 regardless — mirroring the RFC
    # 3501 `n:*` quirk where a server can legitimately return an OLD message.
    # The client-side filter is what actually enforces the watermark.
    assert {:ok, _client, [8, 11]} = ImapClient.uid_search_after(logged_in(port), 5)
  end

  test "highest_uid/1 reports the newest message", %{port: port} do
    assert {:ok, _client, 11} = ImapClient.highest_uid(logged_in(port))
  end

  test "reads a literal-framed FETCH body back byte-for-byte", %{port: port} do
    assert {:ok, client, raw} = ImapClient.uid_fetch_raw(logged_in(port), 8)
    assert raw == @raw_message

    # The trailing ")" and tagged OK after the literal must have been consumed,
    # so the next command still lines up on the same connection.
    assert {:ok, _client, :ok} = ImapClient.uid_mark_seen(client, 8)
  end

  test "with_connection/2 connects, logs in, runs the body and closes", %{port: port} do
    {:ok, inbox} =
      EmailInboxes.create_email_inbox(%{
        name: "fake",
        host: "127.0.0.1",
        port: port,
        tls: false,
        username: "ops@example.com",
        password: "hunter2"
      })

    assert {:ok, mailbox} =
             ImapClient.with_connection(inbox, fn client ->
               ImapClient.select(client, "INBOX")
             end)

    assert mailbox.uid_validity == 99
  end

  test "with_connection/2 surfaces a bad password as a login failure", %{port: port} do
    {:ok, inbox} =
      EmailInboxes.create_email_inbox(%{
        name: "fake bad password",
        host: "127.0.0.1",
        port: port,
        tls: false,
        username: "ops@example.com",
        password: "wrong"
      })

    assert {:error, :login_failed} =
             ImapClient.with_connection(inbox, fn client ->
               ImapClient.select(client, "INBOX")
             end)
  end

  test "a refused connection is an error, not a crash" do
    # Port 1 on loopback: nothing listens, and binding it needs root.
    assert {:error, {:connect_failed, _}} = ImapClient.connect("127.0.0.1", 1, false)
  end

  # ── fake server ─────────────────────────────────────────────────────────

  defp accept_loop(listen) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn ->
          :gen_tcp.send(socket, "* OK fake IMAP ready\r\n")
          serve(socket, "")
        end)

        accept_loop(listen)

      {:error, _} ->
        :ok
    end
  end

  defp serve(socket, buffer) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> handle_lines(socket, buffer <> data)
      {:error, _} -> :ok
    end
  end

  defp handle_lines(socket, buffer) do
    case String.split(buffer, "\r\n", parts: 2) do
      [line, rest] ->
        case respond(socket, line) do
          :stop -> :gen_tcp.close(socket)
          :ok -> handle_lines(socket, rest)
        end

      [partial] ->
        serve(socket, partial)
    end
  end

  defp respond(socket, line) do
    [tag, command] = String.split(line, " ", parts: 2)
    upcased = String.upcase(command)

    cond do
      String.starts_with?(upcased, "LOGIN") and String.contains?(command, "hunter2") ->
        send_lines(socket, ["#{tag} OK LOGIN completed"])

      String.starts_with?(upcased, "LOGIN") ->
        send_lines(socket, ["#{tag} NO [AUTHENTICATIONFAILED] Invalid credentials"])

      String.starts_with?(upcased, "SELECT") ->
        send_lines(socket, [
          "* 3 EXISTS",
          "* 0 RECENT",
          "* OK [UIDVALIDITY 99] UIDs valid",
          "* OK [UIDNEXT 12] Predicted next UID",
          "#{tag} OK [READ-WRITE] SELECT completed"
        ])

      String.starts_with?(upcased, "UID SEARCH") ->
        send_lines(socket, ["* SEARCH 5 8 11", "#{tag} OK UID SEARCH completed"])

      String.starts_with?(upcased, "UID FETCH") ->
        # Literal-framed, exactly as a real server answers BODY.PEEK[].
        :gen_tcp.send(
          socket,
          "* 2 FETCH (UID 8 BODY[] {#{byte_size(@raw_message)}}\r\n" <>
            @raw_message <> ")\r\n#{tag} OK UID FETCH completed\r\n"
        )

        :ok

      String.starts_with?(upcased, "UID STORE") ->
        send_lines(socket, ["* 2 FETCH (UID 8 FLAGS (\\Seen))", "#{tag} OK UID STORE completed"])

      String.starts_with?(upcased, "LOGOUT") ->
        send_lines(socket, ["* BYE logging out", "#{tag} OK LOGOUT completed"])
        :stop

      true ->
        send_lines(socket, ["#{tag} BAD unsupported in fake server"])
    end
  end

  defp send_lines(socket, lines) do
    :gen_tcp.send(socket, Enum.map_join(lines, "", &(&1 <> "\r\n")))
    :ok
  end
end
