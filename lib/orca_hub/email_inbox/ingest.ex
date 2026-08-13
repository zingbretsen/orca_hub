defmodule OrcaHub.EmailInbox.Ingest do
  @moduledoc """
  The accept/reject pipeline for one inbound message: authenticate the
  sender, match it against a trigger's allow-list and routing rules, and —
  only on accept — fire that trigger on its project's node.

  This is the testable seam for the whole feature: `ingest/3` takes an inbox
  row, a raw RFC822 binary, and the candidate triggers for that inbox, so
  every security test runs against canned message sources with no live IMAP
  server involved.

  It never raises. A malformed or hostile message is a `{:rejected, reason}`,
  logged and dropped — the poller must survive anything a stranger can put in
  a mailbox.
  """

  require Logger

  alias OrcaHub.{Cluster, TriggerExecutor}
  alias OrcaHub.EmailInbox.Security

  # Body text handed to the agent, before the prompt is assembled. Generous
  # enough for a real forwarded thread, small enough not to blow up a turn.
  @max_body_bytes 16_000

  # Total decoded attachment bytes kept per message. Overriding it drops the
  # attachments only — the email itself is still processed.
  @default_max_attachment_bytes 10 * 1024 * 1024

  @doc """
  Run one message through the pipeline, firing the matched trigger on accept.

  Returns `{:accepted, trigger_id, result}` where `result` is whatever
  `TriggerExecutor.execute_payload/2` returned, or `{:rejected, reason}`.
  """
  def ingest(inbox, raw, triggers) when is_binary(raw) and is_list(triggers) do
    case decide(inbox, raw, triggers) do
      {:accept, trigger, payload} -> fire(trigger, payload)
      {:reject, reason} -> reject(inbox, raw, reason)
    end
  end

  @doc """
  The decision half of `ingest/3`, with no side effects: authenticate, match,
  route, and build the normalized payload.

  Returns `{:accept, trigger, payload}` or `{:reject, reason}`. `triggers`
  need only carry `:name`, `:sender_allowlist`, `:to_address` and
  `:subject_pattern`, and `inbox` only `:trusted_authserv_id` — so the
  security tests run against canned RFC822 strings with no database, no IMAP
  server, and no session.

  Never raises: a hostile or malformed message is a `{:reject, _}`.
  """
  def decide(inbox, raw, triggers) when is_binary(raw) and is_list(triggers) do
    with {:ok, from} <- Security.from_address(raw),
         :ok <- authenticate(raw, from, inbox),
         {:ok, parsed} <- parse(raw),
         {:ok, trigger} <- pick_trigger(from, parsed, triggers) do
      {:accept, trigger, payload(from, parsed)}
    else
      {:error, reason} -> {:reject, reason}
    end
  rescue
    # Belt-and-braces: the pipeline is written not to raise, but a hostile
    # message must never be able to take the poller down through an
    # unanticipated path in a parsing library.
    e ->
      {:reject, {:exception, Exception.message(e)}}
  end

  @doc """
  Neutralize an attacker-supplied attachment filename for DISPLAY.

  Strips any directory component and rejects the traversal/`nil`/blank
  degenerate cases, falling back to `"attachment"`. The result is still
  attacker-chosen text and must never be used as a real path component — see
  `write_attachments/2`, which generates the on-disk name itself.

      iex> OrcaHub.EmailInbox.Ingest.sanitize_filename("../../etc/passwd")
      "passwd"
      iex> OrcaHub.EmailInbox.Ingest.sanitize_filename("invoice.pdf")
      "invoice.pdf"
  """
  def sanitize_filename(name) when is_binary(name) do
    name
    # Windows separators survive Path.basename/1 on Unix, so fold them into
    # "/" first; a "..\\..\\windows\\system32\\x" name must not come back whole.
    |> String.replace("\\", "/")
    |> String.replace(~r/[\x00-\x1f]/, "")
    |> Path.basename()
    |> String.trim()
    |> case do
      "" -> "attachment"
      "." -> "attachment"
      ".." -> "attachment"
      basename -> basename
    end
  end

  def sanitize_filename(_), do: "attachment"

  @doc """
  Write `attachments` (a list of `%{"filename" => display_name, "data" =>
  binary}`) into `dir`'s `.orca_email_attachments/` and return the absolute
  paths written, in order.

  Called from `TriggerExecutor.execute_payload/2`, i.e. already on the
  session's runner node. The on-disk name is GENERATED (`attachment_<n><ext>`)
  rather than derived from the sender's filename — the sanitized name is only
  ever shown to the agent in the prompt.
  """
  def write_attachments(_dir, []), do: []

  def write_attachments(dir, attachments) when is_binary(dir) and is_list(attachments) do
    target = Path.join(dir, ".orca_email_attachments")

    case File.mkdir_p(target) do
      :ok ->
        attachments
        |> Enum.with_index(1)
        |> Enum.flat_map(fn {attachment, index} -> write_one(target, attachment, index) end)

      {:error, reason} ->
        Logger.warning(
          "Email attachments: could not create #{target}: #{:file.format_error(reason)}"
        )

        []
    end
  end

  @doc "Max total attachment bytes kept per message (ORCA_EMAIL_MAX_ATTACHMENT_BYTES)."
  def max_attachment_bytes do
    Application.get_env(:orca_hub, :email_max_attachment_bytes, @default_max_attachment_bytes)
  end

  # ── pipeline steps ──────────────────────────────────────────────────────

  defp authenticate(raw, from, inbox) do
    Security.verify_authentication(raw, from, Map.get(inbox, :trusted_authserv_id))
  end

  defp parse(raw) do
    message = Mail.parse(raw)

    {:ok,
     %{
       to: recipients(message),
       subject: header_string(message, "subject"),
       message_id: header_string(message, "message-id"),
       in_reply_to: header_string(message, "in-reply-to"),
       body: message |> extract_body() |> strip_quoted_reply() |> cap_body(),
       attachments: extract_attachments(message)
     }}
  rescue
    e -> {:error, {:unparseable, Exception.message(e)}}
  end

  # Eligible = allow-listed sender AND every routing rule the trigger states.
  # More specific triggers win, so a catch-all can share an inbox with a
  # narrowly-routed one; ties break on name for determinism.
  defp pick_trigger(from, parsed, triggers) do
    allowed = Enum.filter(triggers, &Security.allowed_sender?(from, &1.sender_allowlist || []))

    matching = Enum.filter(allowed, &routes_to?(&1, parsed))

    cond do
      allowed == [] -> {:error, :sender_not_allowed}
      matching == [] -> {:error, :no_matching_trigger}
      true -> {:ok, Enum.min_by(matching, &{-specificity(&1), &1.name})}
    end
  end

  defp routes_to?(trigger, parsed) do
    to_matches?(trigger.to_address, parsed.to) and
      subject_matches?(trigger.subject_pattern, parsed.subject)
  end

  defp to_matches?(nil, _), do: true
  defp to_matches?("", _), do: true

  defp to_matches?(address, recipients) do
    wanted = address |> String.trim() |> String.downcase()
    Enum.any?(recipients, &(&1 == wanted))
  end

  defp subject_matches?(nil, _), do: true
  defp subject_matches?("", _), do: true

  defp subject_matches?(pattern, subject) do
    String.contains?(String.downcase(subject || ""), String.downcase(String.trim(pattern)))
  end

  defp specificity(trigger) do
    count = fn
      nil -> 0
      "" -> 0
      _ -> 1
    end

    count.(trigger.to_address) + count.(trigger.subject_pattern)
  end

  defp payload(from, parsed) do
    %{
      # Explicit discriminant so TriggerExecutor.build_prompt/2 matches on
      # shape rather than guessing from which keys happen to be present.
      # ATOM key and value, deliberately: a webhook body arrives as a
      # string-keyed map decoded from JSON, so it can never spell this and
      # talk build_prompt/2 into vouching for content nobody authenticated.
      :source => :email,
      "from" => from,
      "to" => Enum.join(parsed.to, ", "),
      "subject" => parsed.subject,
      "body" => parsed.body,
      "message_id" => parsed.message_id,
      "in_reply_to" => parsed.in_reply_to,
      # Raw bytes ride along in the payload; execute_payload/2 runs entirely
      # on the runner node, so the write lands on the right filesystem
      # without a second transfer hop.
      "attachments" => parsed.attachments
    }
  end

  defp fire(trigger, payload) do
    runner_node =
      if trigger.project, do: Cluster.project_node_for(trigger.project), else: node()

    Logger.info(
      "Email trigger #{trigger.name} (#{trigger.id}) accepted a message from " <>
        mask(payload["from"])
    )

    case Cluster.rpc(runner_node, TriggerExecutor, :execute_payload, [trigger.id, payload]) do
      {:error, _} = error ->
        Logger.warning(
          "Email trigger #{trigger.name} (#{trigger.id}) failed to fire on " <>
            "#{inspect(runner_node)}: #{inspect(error)}"
        )

        {:accepted, trigger.id, error}

      result ->
        {:accepted, trigger.id, result}
    end
  end

  defp reject(inbox, raw, reason) do
    from =
      case Security.from_address(raw) do
        {:ok, addr} -> mask(addr)
        _ -> "(unparseable From)"
      end

    Logger.warning(
      "Email inbox #{Map.get(inbox, :name, "unknown")}: rejected message from #{from} — " <>
        inspect(reason)
    )

    {:rejected, reason}
  end

  # Enough to identify a sender in a log without writing a full address (and
  # anything after it) into the log file.
  defp mask(addr) when is_binary(addr) do
    case String.split(addr, "@") do
      [local, domain] -> String.slice(local, 0, 2) <> "***@" <> domain
      _ -> "***"
    end
  end

  defp mask(_), do: "***"

  # ── message extraction ──────────────────────────────────────────────────

  defp recipients(message) do
    ["to", "cc"]
    |> Enum.flat_map(fn header ->
      case Mail.Message.get_header(message, header) do
        nil -> []
        values -> List.wrap(values)
      end
    end)
    |> Enum.flat_map(&address_of/1)
  end

  defp address_of({_name, address}) when is_binary(address), do: [String.downcase(address)]

  defp address_of(value) when is_binary(value) do
    case Security.addr_spec(value) do
      {:ok, addr} -> [addr]
      _ -> []
    end
  end

  defp address_of(_), do: []

  defp header_string(message, header) do
    case Mail.Message.get_header(message, header) do
      value when is_binary(value) -> value
      [value | _] when is_binary(value) -> value
      _ -> nil
    end
  end

  defp extract_body(message) do
    case Mail.get_text(message) do
      %Mail.Message{} = part ->
        body_text(part)

      _ ->
        case Mail.get_html(message) do
          %Mail.Message{} = part -> part |> body_text() |> strip_html()
          _ -> body_text(message)
        end
    end
  end

  defp body_text(%Mail.Message{body: body}) when is_binary(body), do: body
  defp body_text(%Mail.Message{body: body}) when is_list(body), do: Enum.join(body, "\n")
  defp body_text(_), do: ""

  defp strip_html(html) do
    html
    |> String.replace(~r{<(script|style)[^>]*>.*?</\1>}is, " ")
    |> String.replace(~r{<br\s*/?>}i, "\n")
    |> String.replace(~r{</p>}i, "\n\n")
    |> String.replace(~r{<[^>]*>}, "")
    |> String.replace(~r/\n{3,}/, "\n\n")
    |> String.trim()
  end

  # Heuristic, not exact: drop `>`-quoted lines and everything after a
  # recognizable attribution/forward separator. Good enough to keep a reply
  # chain from dominating the prompt.
  defp strip_quoted_reply(body) do
    body
    |> String.split(~r/\r?\n/)
    |> Enum.reduce_while([], fn line, acc ->
      cond do
        quote_separator?(line) -> {:halt, acc}
        String.starts_with?(String.trim_leading(line), ">") -> {:cont, acc}
        true -> {:cont, [line | acc]}
      end
    end)
    |> Enum.reverse()
    |> Enum.join("\n")
    |> String.trim()
  end

  defp quote_separator?(line) do
    trimmed = String.trim(line)

    String.match?(trimmed, ~r/^On .*wrote:$/i) or
      String.match?(trimmed, ~r/^-{2,}\s*Original Message\s*-{2,}$/i) or
      String.match?(trimmed, ~r/^-{2,}\s*Forwarded message\s*-{2,}$/i) or
      String.match?(trimmed, ~r/^_{10,}$/)
  end

  defp cap_body(body) when byte_size(body) <= @max_body_bytes, do: body

  defp cap_body(body) do
    binary_part(body, 0, @max_body_bytes) <> "\n\n[truncated]"
  end

  defp extract_attachments(message) do
    attachments =
      message
      |> Mail.get_attachments()
      |> Enum.filter(fn {_name, data} -> is_binary(data) end)
      |> Enum.map(fn {name, data} ->
        %{"filename" => sanitize_filename(name), "data" => data}
      end)

    total = Enum.reduce(attachments, 0, fn %{"data" => data}, acc -> acc + byte_size(data) end)

    if total > max_attachment_bytes() do
      Logger.warning(
        "Email attachments dropped: #{total} bytes exceeds the " <>
          "#{max_attachment_bytes()}-byte cap (the email itself is still processed)"
      )

      []
    else
      attachments
    end
  end

  defp write_one(target, %{"filename" => display_name, "data" => data}, index)
       when is_binary(data) do
    # The on-disk name is ours, not the sender's — the sanitized display name
    # only reaches the prompt. Only the extension is carried over, and only
    # after basename-stripping, so it cannot contain a path separator.
    extension = display_name |> sanitize_filename() |> Path.extname() |> String.slice(0, 16)
    path = Path.join(target, "attachment_#{index}#{extension}")

    case File.write(path, data) do
      :ok ->
        [path]

      {:error, reason} ->
        Logger.warning("Email attachment write failed (#{path}): #{:file.format_error(reason)}")
        []
    end
  end

  defp write_one(_target, _attachment, _index), do: []
end
