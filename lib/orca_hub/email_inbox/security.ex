defmodule OrcaHub.EmailInbox.Security do
  @moduledoc """
  Pure sender-authentication and allow-list functions for inbound email.

  Everything here works on the RAW RFC822 source rather than a parsed
  `%Mail.Message{}`, deliberately:

  `Mail.Parsers.RFC2822` folds repeated headers with `Map.put/3` (only
  `received` accumulates a list), walking the header block top-to-bottom — so
  the parsed `.headers` map ends up holding the BOTTOM-MOST occurrence of any
  repeated header. Each relay PREPENDS its own headers, so the bottom-most
  `Authentication-Results` is the oldest/most-distant hop — potentially one
  the sender wrote themselves — while the TOP-MOST is the one our own
  receiving infrastructure just added. Reading `Authentication-Results`
  through the parsed map would therefore hand an attacker a trivial spoof
  (append a fake `Authentication-Results: ...; dmarc=pass` to their own
  message and it wins). We scan the raw header block and take the top-most
  occurrence instead.

  "Top-most is trustworthy" holds as long as the receiving MTA strips inbound
  untrusted `Authentication-Results` headers before adding its own — standard
  practice at Gmail/SES/etc. `EmailInbox.trusted_authserv_id` pins the exact
  authserv-id to accept as defense in depth on top of that.

  `From:` is read from the raw source for the same reason, and a message
  carrying more than one `From:` header is rejected outright (RFC 5322 allows
  exactly one; more is an evasion attempt, and which one DMARC evaluated is
  then ambiguous).
  """

  @doc """
  Unfolded header lines of `raw`, in raw top-to-bottom order.

  Continuation lines (leading space/tab) are joined onto the preceding
  header with a single space, matching RFC 5322 unfolding.
  """
  def header_lines(raw) when is_binary(raw) do
    raw
    |> header_block()
    |> String.split(~r/\r?\n/)
    |> Enum.reduce([], fn
      <<ws, _::binary>> = line, [prev | rest] when ws in [?\s, ?\t] ->
        [prev <> " " <> String.trim_leading(line) | rest]

      # A continuation line with no preceding header is malformed; drop it.
      <<ws, _::binary>>, [] when ws in [?\s, ?\t] ->
        []

      line, acc ->
        [line | acc]
    end)
    |> Enum.reverse()
  end

  @doc """
  Every value of header `name` (matched case-insensitively) in `raw`, in raw
  top-to-bottom order — so the head of the list is the most recently added
  (most trusted) hop's.
  """
  def header_values(raw, name) when is_binary(raw) and is_binary(name) do
    prefix = String.downcase(name) <> ":"
    prefix_size = byte_size(prefix)

    raw
    |> header_lines()
    |> Enum.filter(fn line ->
      String.downcase(binary_part(line, 0, min(prefix_size, byte_size(line)))) == prefix
    end)
    |> Enum.map(fn line ->
      line |> binary_part(prefix_size, byte_size(line) - prefix_size) |> String.trim()
    end)
  end

  @doc """
  The sender's addr-spec (downcased), taken from the message's single `From:`
  header. Never the display name.

  Returns `{:ok, addr}` or `{:error, reason}`.
  """
  def from_address(raw) when is_binary(raw) do
    case header_values(raw, "from") do
      [] -> {:error, :missing_from}
      [value] -> addr_spec(value)
      _multiple -> {:error, :multiple_from_headers}
    end
  end

  @doc """
  Extract the addr-spec from a single address header value.

      iex> OrcaHub.EmailInbox.Security.addr_spec(~s("zach@x.com" <attacker@evil.com>))
      {:ok, "attacker@evil.com"}

  A display name — quoted or not, and even one containing an `@` or its own
  angle brackets — is never returned. When angle brackets are present the
  LAST bracketed group wins, since that is where the real addr-spec sits in
  `name-addr` form.
  """
  def addr_spec(value) when is_binary(value) do
    value
    |> strip_comments()
    |> extract_addr()
    |> case do
      nil ->
        {:error, :unparseable_address}

      candidate ->
        addr = candidate |> String.trim() |> String.downcase()
        if valid_addr_spec?(addr), do: {:ok, addr}, else: {:error, :unparseable_address}
    end
  end

  @doc """
  Does `addr` match `allowlist`?

  Entries containing `@` are matched as whole addresses; bare entries are
  matched against the address's domain. Both are case-insensitive and exact —
  a bare `example.com` entry does NOT match `mail.example.com`, so widening
  the allow-list is always an explicit act.
  """
  def allowed_sender?(addr, allowlist) when is_binary(addr) and is_list(allowlist) do
    addr = String.downcase(String.trim(addr))
    domain = domain_of(addr)

    Enum.any?(allowlist, fn entry ->
      case normalize_entry(entry) do
        "" ->
          false

        entry when is_binary(entry) ->
          if String.contains?(entry, "@"), do: entry == addr, else: entry == domain
      end
    end)
  end

  @doc """
  Verify the message's sender authentication.

  Accepts only on `dmarc=pass` (with `header.from` aligned to the `From:`
  domain when the header reports one), or `dkim=pass` whose `header.d`/
  `header.i` domain is aligned with the `From:` domain. A message with no
  usable `Authentication-Results` header is rejected — the raw `From:` string
  is never trusted on its own.

  Returns `:ok` or `{:error, reason}`.
  """
  def verify_authentication(raw, from_addr, trusted_authserv_id \\ nil)
      when is_binary(raw) and is_binary(from_addr) do
    case trusted_authentication_results(raw, trusted_authserv_id) do
      nil ->
        if header_values(raw, "authentication-results") == [] do
          {:error, :no_authentication_results}
        else
          {:error, :untrusted_authserv_id}
        end

      value ->
        results = parse_authentication_results(value)
        from_domain = domain_of(from_addr)

        cond do
          dmarc_pass?(results, from_domain) -> :ok
          dkim_aligned_pass?(results, from_domain) -> :ok
          true -> {:error, :authentication_failed}
        end
    end
  end

  @doc """
  The `Authentication-Results` value we're willing to trust: the TOP-MOST
  occurrence, or — when the inbox pins a `trusted_authserv_id` — the top-most
  occurrence whose authserv-id matches that pin. `nil` if there is none.
  """
  def trusted_authentication_results(raw, trusted_authserv_id \\ nil) do
    values = header_values(raw, "authentication-results")
    pin = normalize_entry(trusted_authserv_id)

    if pin == "" do
      List.first(values)
    else
      Enum.find(values, fn value ->
        parse_authentication_results(value).authserv_id == pin
      end)
    end
  end

  @doc """
  Parse an `Authentication-Results` value into
  `%{authserv_id: String.t(), methods: [%{method:, result:, props: map}]}`.
  """
  def parse_authentication_results(value) when is_binary(value) do
    [authserv | method_chunks] = value |> strip_comments() |> String.split(";")

    authserv_id =
      authserv
      |> String.trim()
      |> String.split(~r/\s+/, parts: 2)
      |> List.first()
      |> to_string()
      |> String.downcase()

    %{authserv_id: authserv_id, methods: Enum.flat_map(method_chunks, &parse_method_chunk/1)}
  end

  # ── internals ───────────────────────────────────────────────────────────

  defp header_block(raw) do
    case String.split(raw, ~r/\r?\n\r?\n/, parts: 2) do
      [headers, _body] -> headers
      [headers] -> headers
    end
  end

  # Drop RFC 5322 parenthesized comments, e.g.
  # `dkim=pass (2048-bit key) header.d=example.com`. Nesting is handled by
  # depth counting; an unbalanced "(" swallows the rest, which is the safe
  # direction (we lose a claim rather than inventing one).
  defp strip_comments(value) do
    value
    |> String.to_charlist()
    |> Enum.reduce({[], 0}, fn
      ?(, {acc, depth} -> {acc, depth + 1}
      ?), {acc, depth} when depth > 0 -> {acc, depth - 1}
      _char, {acc, depth} when depth > 0 -> {acc, depth}
      char, {acc, 0} -> {[char | acc], 0}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> List.to_string()
  end

  defp extract_addr(value) do
    case Regex.scan(~r/<([^<>]*)>/, value) do
      [] ->
        value
        |> String.split(~r/[\s,]+/, trim: true)
        |> Enum.filter(&String.contains?(&1, "@"))
        |> case do
          [single] -> single
          _ -> nil
        end

      matches ->
        matches |> List.last() |> Enum.at(1)
    end
  end

  defp valid_addr_spec?(addr) do
    case String.split(addr, "@") do
      [local, domain] ->
        local != "" and domain != "" and String.contains?(domain, ".") and
          not String.match?(addr, ~r/[\s,<>"]/)

      _ ->
        false
    end
  end

  defp normalize_entry(nil), do: ""

  defp normalize_entry(entry) when is_binary(entry),
    do: entry |> String.trim() |> String.downcase()

  defp normalize_entry(_), do: ""

  @doc "The domain part of an addr-spec, downcased (`\"\"` if there isn't one)."
  def domain_of(addr) when is_binary(addr) do
    addr
    |> String.downcase()
    |> String.split("@")
    |> List.last()
    |> String.trim()
    |> String.trim_trailing(">")
  end

  defp parse_method_chunk(chunk) do
    case chunk |> String.trim() |> String.split(~r/\s+/, trim: true) do
      [] ->
        []

      [head | rest] ->
        case String.split(head, "=", parts: 2) do
          [method, result] ->
            [
              %{
                method: String.downcase(String.trim(method)),
                result: result |> String.trim() |> String.downcase() |> strip_quotes(),
                props: Map.new(rest, &parse_prop/1)
              }
            ]

          _ ->
            []
        end
    end
  end

  defp parse_prop(token) do
    case String.split(token, "=", parts: 2) do
      [key, value] -> {String.downcase(key), value |> String.downcase() |> strip_quotes()}
      [key] -> {String.downcase(key), ""}
    end
  end

  defp strip_quotes(value), do: String.trim(value, "\"")

  defp dmarc_pass?(%{methods: methods}, from_domain) do
    Enum.any?(methods, fn
      %{method: "dmarc", result: "pass", props: props} ->
        case Map.get(props, "header.from") do
          # Some providers omit header.from; DMARC is From-domain-scoped by
          # definition, so a bare `dmarc=pass` from a trusted authserv-id is
          # accepted. When it IS reported, it must align.
          nil -> true
          reported -> aligned?(strip_domain(reported), from_domain)
        end

      _ ->
        false
    end)
  end

  defp dkim_aligned_pass?(%{methods: methods}, from_domain) do
    Enum.any?(methods, fn
      %{method: "dkim", result: "pass", props: props} ->
        [Map.get(props, "header.d"), Map.get(props, "header.i")]
        |> Enum.reject(&is_nil/1)
        |> Enum.any?(fn value -> aligned?(strip_domain(value), from_domain) end)

      _ ->
        false
    end)
  end

  # `header.i` looks like "@example.com" or "user@example.com"; `header.d`
  # and `header.from` are bare domains (sometimes angle-wrapped).
  defp strip_domain(value) do
    value
    |> String.trim()
    |> String.trim("<")
    |> String.trim(">")
    |> String.split("@")
    |> List.last()
    |> String.downcase()
  end

  # Relaxed alignment without a public-suffix list: exact match, or one is a
  # subdomain of the other. Strict enough for the "dmarc=pass for the WRONG
  # domain" case while tolerating `mail.example.com` vs `example.com`.
  defp aligned?("", _), do: false
  defp aligned?(_, ""), do: false

  defp aligned?(a, b) do
    a == b or String.ends_with?(a, "." <> b) or String.ends_with?(b, "." <> a)
  end
end
