defmodule OrcaHub.EmailInbox.ImapClient do
  @moduledoc """
  A deliberately small IMAP4rev1 client — just the commands the inbound-email
  poller needs: `LOGIN`, `SELECT`, `UID SEARCH`, `UID FETCH BODY.PEEK[]`,
  `UID STORE +FLAGS (\\Seen)`, `LOGOUT`.

  This is not a general IMAP library and shouldn't grow into one. It exists
  because the feature needs the RAW RFC822 source of each message: every
  maintained IMAP package on hex hands back a curated struct with no escape
  hatch to the original headers, and `Authentication-Results` — the header
  the whole security model rests on — is not in any of those structs. See
  `OrcaHub.EmailInbox.Security`.

  Every function returns `{:ok, client, result}` / `{:error, reason}` and
  threads an updated `%ImapClient{}` (the socket read buffer lives in it).
  Nothing here raises on protocol or network failure; the poller logs and
  retries on the next tick.
  """

  require Logger

  defstruct [:transport, :socket, tag: 0, buffer: ""]

  @connect_timeout 15_000
  @recv_timeout 30_000
  @test_connection_timeout 20_000

  @type t :: %__MODULE__{}

  @doc """
  Connect, `LOGIN`, run `fun.(client)`, then `LOGOUT` and close — even if
  `fun` returns an error or raises.

  `fun` receives a logged-in client and must return `{:ok, client, result}`;
  `with_connection/2` returns `{:ok, result}` or `{:error, reason}`.
  """
  def with_connection(inbox, fun) when is_function(fun, 1) do
    with {:ok, client} <- connect(inbox.host, inbox.port, inbox.tls),
         {:ok, client} <- login(client, inbox.username, OrcaHub.EmailInboxes.password!(inbox)) do
      try do
        case fun.(client) do
          {:ok, _client, result} -> {:ok, result}
          {:error, reason} -> {:error, reason}
        end
      after
        close(client)
      end
    end
  end

  @doc "Open a socket and consume the server greeting."
  def connect(host, port, tls?) do
    transport = if tls?, do: :ssl, else: :gen_tcp
    host_charlist = String.to_charlist(host)

    opts =
      [:binary, packet: :raw, active: false] ++
        if tls? do
          [
            verify: :verify_peer,
            cacerts: :public_key.cacerts_get(),
            server_name_indication: host_charlist,
            depth: 4,
            customize_hostname_check: [
              match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
            ]
          ]
        else
          []
        end

    case transport.connect(host_charlist, port, opts, @connect_timeout) do
      {:ok, socket} ->
        client = %__MODULE__{transport: transport, socket: socket}

        # Untagged greeting: "* OK [CAPABILITY ...] server ready".
        case read_logical_line(client) do
          {:ok, client, {"* OK" <> _, _}} -> {:ok, client}
          {:ok, _client, {line, _}} -> {:error, {:greeting_failed, line}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  def login(client, username, password) do
    case command(client, "LOGIN #{quoted(username)} #{quoted(password)}") do
      # Never echo the command back into an error — it contains the password.
      {:ok, client, _lines} -> {:ok, client}
      {:error, {:command_failed, _line}} -> {:error, :login_failed}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `SELECT` the folder read-write, returning
  `%{uid_validity: integer | nil, uid_next: integer | nil, exists: integer | nil}`.
  """
  def select(client, folder) do
    with {:ok, client, lines} <- command(client, "SELECT #{quoted(folder)}") do
      {:ok, client,
       %{
         uid_validity: scan_bracket_number(lines, "UIDVALIDITY"),
         uid_next: scan_bracket_number(lines, "UIDNEXT"),
         exists: scan_exists(lines)
       }}
    end
  end

  @doc """
  UIDs strictly greater than `last_uid`, ascending.

  The server-side filter is only half the job: RFC 3501 sequence sets treat
  `n:*` as `*:n` when the mailbox's highest UID is below `n`, so a server can
  legitimately answer with an OLD message. The `> last_uid` filter here is
  what actually enforces the watermark.
  """
  def uid_search_after(client, last_uid) when is_integer(last_uid) do
    with {:ok, client, lines} <- command(client, "UID SEARCH UID #{last_uid + 1}:*") do
      uids =
        lines
        |> Enum.filter(&match?("* SEARCH" <> _, elem(&1, 0)))
        |> Enum.flat_map(fn {line, _literals} ->
          line
          |> String.replace_prefix("* SEARCH", "")
          |> String.split(~r/\s+/, trim: true)
          |> Enum.flat_map(&parse_integer/1)
        end)
        |> Enum.filter(&(&1 > last_uid))
        |> Enum.sort()
        |> Enum.uniq()

      {:ok, client, uids}
    end
  end

  @doc "The mailbox's highest UID, or 0 for an empty mailbox."
  def highest_uid(client) do
    with {:ok, client, lines} <- command(client, "UID SEARCH ALL") do
      uids =
        lines
        |> Enum.filter(&match?("* SEARCH" <> _, elem(&1, 0)))
        |> Enum.flat_map(fn {line, _literals} ->
          line
          |> String.replace_prefix("* SEARCH", "")
          |> String.split(~r/\s+/, trim: true)
          |> Enum.flat_map(&parse_integer/1)
        end)

      {:ok, client, Enum.max(uids, fn -> 0 end)}
    end
  end

  @doc """
  Fetch the raw RFC822 source of `uid` with `BODY.PEEK[]`, which — unlike
  `BODY[]` — does NOT set `\\Seen` as a side effect. The poller sets that flag
  itself, deliberately, as part of its watermark commit.
  """
  def uid_fetch_raw(client, uid) when is_integer(uid) do
    with {:ok, client, lines} <- command(client, "UID FETCH #{uid} (BODY.PEEK[])") do
      case Enum.find_value(lines, fn {_line, literals} -> List.first(literals) end) do
        nil -> {:error, {:no_body, uid}}
        raw -> {:ok, client, raw}
      end
    end
  end

  @doc "Mark `uid` `\\Seen`."
  def uid_mark_seen(client, uid) when is_integer(uid) do
    with {:ok, client, _lines} <- command(client, "UID STORE #{uid} +FLAGS (\\Seen)") do
      {:ok, client, :ok}
    end
  end

  @doc """
  Connect, `LOGIN`, `SELECT` `folder`, then `LOGOUT` and disconnect —
  without fetching or mutating any messages. For "test connection" UI
  buttons only.

  Bounded to #{@test_connection_timeout}ms wall-clock via a supervised task,
  independent of (and shorter than) the `@connect_timeout` / `@recv_timeout`
  used internally — a bad hostname or a server that accepts the TCP
  connection but never answers would otherwise be able to hold the caller
  for the internal timeouts' full duration.
  """
  def test_connection(%{
        host: host,
        port: port,
        tls: tls,
        username: username,
        password: password,
        folder: folder
      }) do
    task = Task.async(fn -> run_test_connection(host, port, tls, username, password, folder) end)

    case Task.yield(task, @test_connection_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:crashed, reason}}
      nil -> {:error, :timeout}
    end
  end

  defp run_test_connection(host, port, tls, username, password, folder) do
    with {:ok, client} <- connect(host, port, tls) do
      try do
        with {:ok, client} <- login(client, username, password),
             {:ok, _client, _info} <- select(client, folder) do
          :ok
        end
      after
        close(client)
      end
    end
  end

  @doc "Best-effort `LOGOUT` + socket close. Always returns `:ok`."
  def close(client) do
    _ = command(client, "LOGOUT")
    client.transport.close(client.socket)
    :ok
  catch
    _, _ -> :ok
  end

  # ── protocol plumbing ───────────────────────────────────────────────────

  @doc false
  def command(client, command_string) do
    tag = "A#{String.pad_leading(Integer.to_string(client.tag + 1), 4, "0")}"
    client = %{client | tag: client.tag + 1}

    case client.transport.send(client.socket, tag <> " " <> command_string <> "\r\n") do
      :ok -> read_until_tagged(client, tag, [])
      {:error, reason} -> {:error, {:send_failed, reason}}
    end
  end

  defp read_until_tagged(client, tag, acc) do
    case read_logical_line(client) do
      {:ok, client, {line, _literals} = logical_line} ->
        if String.starts_with?(line, tag <> " ") do
          if String.starts_with?(line, tag <> " OK") do
            {:ok, client, Enum.reverse(acc)}
          else
            {:error, {:command_failed, line}}
          end
        else
          read_until_tagged(client, tag, [logical_line | acc])
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # One logical response line: the text plus any `{N}`-prefixed literals it
  # carried, in order.
  defp read_logical_line(client), do: collect_literals(client, "", [])

  defp collect_literals(client, prefix, literals) do
    with {:ok, client, line} <- read_line(client) do
      line = prefix <> line

      case Regex.run(~r/\{(\d+)\}$/, line) do
        [_, count] ->
          with {:ok, client, data} <- read_bytes(client, String.to_integer(count)) do
            collect_literals(client, line, [data | literals])
          end

        nil ->
          {:ok, client, {line, Enum.reverse(literals)}}
      end
    end
  end

  defp read_line(client) do
    case :binary.match(client.buffer, "\r\n") do
      {position, 2} ->
        line = binary_part(client.buffer, 0, position)
        rest = binary_part(client.buffer, position + 2, byte_size(client.buffer) - position - 2)
        {:ok, %{client | buffer: rest}, line}

      :nomatch ->
        with {:ok, client} <- fill(client), do: read_line(client)
    end
  end

  defp read_bytes(client, count) do
    if byte_size(client.buffer) >= count do
      data = binary_part(client.buffer, 0, count)
      rest = binary_part(client.buffer, count, byte_size(client.buffer) - count)
      {:ok, %{client | buffer: rest}, data}
    else
      with {:ok, client} <- fill(client), do: read_bytes(client, count)
    end
  end

  defp fill(client) do
    case client.transport.recv(client.socket, 0, @recv_timeout) do
      {:ok, data} -> {:ok, %{client | buffer: client.buffer <> data}}
      {:error, reason} -> {:error, {:recv_failed, reason}}
    end
  end

  defp quoted(value) do
    escaped =
      value
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")

    "\"" <> escaped <> "\""
  end

  defp scan_bracket_number(lines, key) do
    Enum.find_value(lines, fn {line, _literals} ->
      case Regex.run(~r/\[#{key}\s+(\d+)\]/i, line) do
        [_, number] -> String.to_integer(number)
        nil -> nil
      end
    end)
  end

  defp scan_exists(lines) do
    Enum.find_value(lines, fn {line, _literals} ->
      case Regex.run(~r/^\*\s+(\d+)\s+EXISTS/i, line) do
        [_, number] -> String.to_integer(number)
        nil -> nil
      end
    end)
  end

  defp parse_integer(token) do
    case Integer.parse(token) do
      {number, ""} -> [number]
      _ -> []
    end
  end
end
