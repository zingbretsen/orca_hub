defmodule OrcaHub.EmailInbox.PollerTest do
  @moduledoc """
  Drives a real `Poller` against a scripted fake IMAP server, covering the
  two behaviours the design leans on hardest: the "start watching from now"
  baseline (a new or renumbered mailbox must never replay its history) and
  the commit-before-fire watermark, which must advance for EVERY examined
  message — including rejected ones — so nothing can ever be re-fired.
  """

  use OrcaHub.DataCase, async: true

  alias OrcaHub.EmailInbox.Poller
  alias OrcaHub.EmailInboxes

  setup do
    {:ok, server} = Agent.start_link(fn -> %{uid_validity: 99, uids: [5, 8, 11], seen: []} end)

    {:ok, listen} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listen)
    acceptor = spawn_link(fn -> accept_loop(listen, server) end)

    on_exit(fn ->
      Process.unlink(acceptor)
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end)

    %{port: port, server: server}
  end

  defp start_poller(port, overrides \\ %{}) do
    {:ok, inbox} =
      EmailInboxes.create_email_inbox(
        Map.merge(
          %{
            name: "poller test #{System.unique_integer([:positive])}",
            host: "127.0.0.1",
            port: port,
            tls: false,
            username: "ops@example.com",
            password: "hunter2"
          },
          overrides
        )
      )

    {:ok, pid} = Poller.start(inbox)
    # The poller is a separate process; let it use this test's sandbox conn.
    Ecto.Adapters.SQL.Sandbox.allow(OrcaHub.Repo, self(), pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    inbox
  end

  defp reload(inbox), do: EmailInboxes.get_email_inbox!(inbox.id)

  test "a first poll baselines the watermark instead of replaying history", %{
    port: port,
    server: server
  } do
    inbox = start_poller(port)

    assert :ok = Poller.poll_now(inbox.id)

    reloaded = reload(inbox)
    assert reloaded.uid_validity == 99
    # Highest existing UID — the three already in the mailbox are NOT examined.
    assert reloaded.last_uid == 11
    assert Agent.get(server, & &1.seen) == []
  end

  test "a later poll examines only messages above the watermark", %{port: port, server: server} do
    inbox = start_poller(port)
    assert :ok = Poller.poll_now(inbox.id)

    Agent.update(server, fn state -> %{state | uids: state.uids ++ [12, 13]} end)
    assert :ok = Poller.poll_now(inbox.id)

    assert reload(inbox).last_uid == 13
    assert Agent.get(server, & &1.seen) == [12, 13]
  end

  # No triggers exist for this inbox, so every message is REJECTED. The
  # watermark and the \Seen flag must still advance — that ordering is what
  # makes a mid-poll crash drop a message rather than duplicate a session.
  test "the watermark advances for rejected messages too", %{port: port, server: server} do
    inbox = start_poller(port)
    assert :ok = Poller.poll_now(inbox.id)

    Agent.update(server, fn state -> %{state | uids: state.uids ++ [12]} end)
    assert :ok = Poller.poll_now(inbox.id)

    assert reload(inbox).last_uid == 12
    assert Agent.get(server, & &1.seen) == [12]

    # And a third poll finds nothing new — no re-fire.
    assert :ok = Poller.poll_now(inbox.id)
    assert Agent.get(server, & &1.seen) == [12]
  end

  test "a UIDVALIDITY change re-baselines instead of reprocessing", %{
    port: port,
    server: server
  } do
    inbox = start_poller(port)
    assert :ok = Poller.poll_now(inbox.id)
    assert reload(inbox).last_uid == 11

    # Server renumbered the mailbox: UIDs are now meaningless, and the low
    # numbers below the old watermark are DIFFERENT messages.
    Agent.update(server, fn state -> %{state | uid_validity: 100, uids: [1, 2, 3]} end)
    assert :ok = Poller.poll_now(inbox.id)

    reloaded = reload(inbox)
    assert reloaded.uid_validity == 100
    assert reloaded.last_uid == 3
    assert Agent.get(server, & &1.seen) == []
  end

  test "a disabled inbox skips the cycle without terminating the poller", %{
    port: port,
    server: server
  } do
    inbox = start_poller(port, %{enabled: false})

    assert :ok = Poller.poll_now(inbox.id)

    assert reload(inbox).last_uid == 0
    assert reload(inbox).uid_validity == nil
    assert Agent.get(server, & &1.seen) == []
  end

  test "an unreachable server logs and returns an error rather than crashing", %{port: port} do
    inbox = start_poller(port)
    # Point the row at a closed port after the poller is already running.
    {:ok, _} = EmailInboxes.update_email_inbox(reload(inbox), %{port: 1})

    assert :error = Poller.poll_now(inbox.id)

    assert Process.alive?(
             GenServer.whereis({:via, Registry, {OrcaHub.EmailInboxRegistry, inbox.id}})
           )
  end

  # ── fake server ─────────────────────────────────────────────────────────

  @raw_message "From: stranger@nowhere.example\r\n" <>
                 "Authentication-Results: mx.trusted.com; dmarc=pass header.from=nowhere.example\r\n" <>
                 "Subject: hi\r\n\r\nbody\r\n"

  defp accept_loop(listen, server) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        spawn(fn ->
          :gen_tcp.send(socket, "* OK fake IMAP ready\r\n")
          serve(socket, server, "")
        end)

        accept_loop(listen, server)

      {:error, _} ->
        :ok
    end
  end

  defp serve(socket, server, buffer) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} -> handle_lines(socket, server, buffer <> data)
      {:error, _} -> :ok
    end
  end

  defp handle_lines(socket, server, buffer) do
    case String.split(buffer, "\r\n", parts: 2) do
      [line, rest] ->
        case respond(socket, server, line) do
          :stop -> :gen_tcp.close(socket)
          :ok -> handle_lines(socket, server, rest)
        end

      [partial] ->
        serve(socket, server, partial)
    end
  end

  defp respond(socket, server, line) do
    [tag, command] = String.split(line, " ", parts: 2)
    upcased = String.upcase(command)
    state = Agent.get(server, & &1)

    cond do
      String.starts_with?(upcased, "LOGIN") ->
        send_lines(socket, ["#{tag} OK LOGIN completed"])

      String.starts_with?(upcased, "SELECT") ->
        send_lines(socket, [
          "* #{length(state.uids)} EXISTS",
          "* OK [UIDVALIDITY #{state.uid_validity}] UIDs valid",
          "* OK [UIDNEXT #{Enum.max(state.uids, fn -> 0 end) + 1}] Predicted next UID",
          "#{tag} OK [READ-WRITE] SELECT completed"
        ])

      String.starts_with?(upcased, "UID SEARCH") ->
        send_lines(socket, [
          "* SEARCH #{Enum.join(state.uids, " ")}",
          "#{tag} OK UID SEARCH completed"
        ])

      String.starts_with?(upcased, "UID FETCH") ->
        :gen_tcp.send(
          socket,
          "* 1 FETCH (UID #{uid_in(command)} BODY[] {#{byte_size(@raw_message)}}\r\n" <>
            @raw_message <> ")\r\n#{tag} OK UID FETCH completed\r\n"
        )

        :ok

      String.starts_with?(upcased, "UID STORE") ->
        uid = uid_in(command)
        Agent.update(server, fn s -> %{s | seen: s.seen ++ [uid]} end)
        send_lines(socket, ["#{tag} OK UID STORE completed"])

      String.starts_with?(upcased, "LOGOUT") ->
        send_lines(socket, ["* BYE", "#{tag} OK LOGOUT completed"])
        :stop

      true ->
        send_lines(socket, ["#{tag} BAD unsupported in fake server"])
    end
  end

  # command is e.g. "UID FETCH 12 (BODY.PEEK[])" — the tag is already stripped.
  defp uid_in(command) do
    command |> String.split(" ", trim: true) |> Enum.at(2) |> String.to_integer()
  end

  defp send_lines(socket, lines) do
    :gen_tcp.send(socket, Enum.map_join(lines, "", &(&1 <> "\r\n")))
    :ok
  end
end
