defmodule OrcaHub.EmailInbox.SecurityTest do
  use ExUnit.Case, async: true

  alias OrcaHub.EmailInbox.Security

  defp crlf(text), do: String.replace(text, ~r/\r?\n/, "\r\n")

  describe "addr_spec/1" do
    test "returns the angle-bracketed addr-spec, never a spoofed display name" do
      assert {:ok, "attacker@evil.com"} =
               Security.addr_spec(~s("zach@x.com" <attacker@evil.com>))
    end

    test "handles an unquoted display name that itself contains an address" do
      assert {:ok, "attacker@evil.com"} = Security.addr_spec("zach@x.com <attacker@evil.com>")
    end

    test "handles a bare addr-spec" do
      assert {:ok, "zach@x.com"} = Security.addr_spec("zach@x.com")
    end

    test "downcases" do
      assert {:ok, "zach@x.com"} = Security.addr_spec("Zach Ingbretsen <Zach@X.CoM>")
    end

    test "ignores an RFC 5322 comment" do
      assert {:ok, "zach@x.com"} = Security.addr_spec("zach@x.com (Zach Ingbretsen)")
    end

    test "rejects a value with no parseable address" do
      assert {:error, :unparseable_address} = Security.addr_spec("not an address")
    end

    test "rejects an ambiguous multi-address value" do
      assert {:error, :unparseable_address} = Security.addr_spec("a@x.com, b@y.com")
    end
  end

  describe "header_values/2 and from_address/1" do
    test "returns repeated headers in raw top-to-bottom order" do
      raw =
        crlf("""
        Authentication-Results: mx.trusted.com; dmarc=pass header.from=x.com
        Authentication-Results: forged.example; dmarc=pass header.from=evil.com
        From: zach@x.com

        body
        """)

      assert [
               "mx.trusted.com; dmarc=pass header.from=x.com",
               "forged.example; dmarc=pass header.from=evil.com"
             ] = Security.header_values(raw, "authentication-results")
    end

    test "unfolds continuation lines" do
      raw =
        crlf("""
        Authentication-Results: mx.trusted.com;
        \tdmarc=pass header.from=x.com
        From: zach@x.com

        body
        """)

      assert ["mx.trusted.com; dmarc=pass header.from=x.com"] =
               Security.header_values(raw, "authentication-results")
    end

    test "rejects a message carrying more than one From: header" do
      raw =
        crlf("""
        From: zach@x.com
        From: attacker@evil.com

        body
        """)

      assert {:error, :multiple_from_headers} = Security.from_address(raw)
    end

    test "rejects a message with no From: header" do
      assert {:error, :missing_from} = Security.from_address(crlf("Subject: hi\n\nbody\n"))
    end
  end

  describe "verify_authentication/3" do
    defp raw_with(auth_headers, from \\ "zach@x.com") do
      crlf("""
      #{auth_headers}From: #{from}
      To: ops@example.com
      Subject: hello

      body
      """)
    end

    test "accepts dmarc=pass aligned with the From: domain" do
      raw = raw_with("Authentication-Results: mx.trusted.com; dmarc=pass header.from=x.com\n")
      assert :ok = Security.verify_authentication(raw, "zach@x.com")
    end

    test "rejects when no Authentication-Results header is present at all" do
      assert {:error, :no_authentication_results} =
               Security.verify_authentication(raw_with(""), "zach@x.com")
    end

    test "rejects dmarc=fail" do
      raw = raw_with("Authentication-Results: mx.trusted.com; dmarc=fail header.from=x.com\n")
      assert {:error, :authentication_failed} = Security.verify_authentication(raw, "zach@x.com")
    end

    test "rejects dmarc=pass reported for a DIFFERENT domain than From:" do
      raw = raw_with("Authentication-Results: mx.trusted.com; dmarc=pass header.from=evil.com\n")
      assert {:error, :authentication_failed} = Security.verify_authentication(raw, "zach@x.com")
    end

    test "accepts dkim=pass whose header.d aligns with the From: domain" do
      raw =
        raw_with("Authentication-Results: mx.trusted.com; spf=pass; dkim=pass header.d=x.com\n")

      assert :ok = Security.verify_authentication(raw, "zach@x.com")
    end

    test "accepts dkim=pass whose header.i aligns with the From: domain" do
      raw = raw_with("Authentication-Results: mx.trusted.com; dkim=pass header.i=@x.com\n")
      assert :ok = Security.verify_authentication(raw, "zach@x.com")
    end

    test "rejects dkim=pass signed by an unaligned domain" do
      raw = raw_with("Authentication-Results: mx.trusted.com; dkim=pass header.d=evil.com\n")
      assert {:error, :authentication_failed} = Security.verify_authentication(raw, "zach@x.com")
    end

    test "ignores parenthesized comments in the header value" do
      raw =
        raw_with(
          "Authentication-Results: mx.trusted.com; dkim=pass (2048-bit key) header.d=x.com\n"
        )

      assert :ok = Security.verify_authentication(raw, "zach@x.com")
    end

    test "tolerates spf=pass alone without treating it as authentication" do
      raw = raw_with("Authentication-Results: mx.trusted.com; spf=pass smtp.mailfrom=x.com\n")
      assert {:error, :authentication_failed} = Security.verify_authentication(raw, "zach@x.com")
    end
  end

  # The bug class this whole module exists for: Mail's parser would hand back
  # the BOTTOM-most Authentication-Results, i.e. the one furthest from us and
  # closest to the sender.
  describe "verify_authentication/3 with repeated Authentication-Results headers" do
    test "uses the TOP-MOST header (our own hop), not a spoofed one below it" do
      raw =
        crlf("""
        Authentication-Results: mx.trusted.com; dmarc=pass header.from=x.com
        Authentication-Results: totally.legit.example; dmarc=pass header.from=evil.com
        From: zach@x.com

        body
        """)

      assert :ok = Security.verify_authentication(raw, "zach@x.com")

      assert "mx.trusted.com; dmarc=pass header.from=x.com" =
               Security.trusted_authentication_results(raw)
    end

    test "a passing header BELOW a failing one cannot rescue the message" do
      raw =
        crlf("""
        Authentication-Results: mx.trusted.com; dmarc=fail header.from=x.com
        Authentication-Results: totally.legit.example; dmarc=pass header.from=x.com
        From: zach@x.com

        body
        """)

      assert {:error, :authentication_failed} = Security.verify_authentication(raw, "zach@x.com")
    end

    test "an attacker-appended header cannot authenticate a message that had none" do
      # A message that arrived with NO trusted A-R, to which the sender
      # appended their own further down the block.
      raw =
        crlf("""
        Received: from mx.trusted.com
        Authentication-Results: sender-controlled.example; dmarc=pass header.from=evil.com
        From: attacker@evil.com

        body
        """)

      # Pinning our provider's authserv-id refuses it outright.
      assert {:error, :untrusted_authserv_id} =
               Security.verify_authentication(raw, "attacker@evil.com", "mx.trusted.com")
    end
  end

  describe "trusted_authentication_results/2 with a pinned authserv-id" do
    test "picks the top-most header matching the pin, skipping others" do
      raw =
        crlf("""
        Authentication-Results: relay.internal; dmarc=none
        Authentication-Results: mx.trusted.com; dmarc=pass header.from=x.com
        From: zach@x.com

        body
        """)

      assert "mx.trusted.com; dmarc=pass header.from=x.com" =
               Security.trusted_authentication_results(raw, "mx.trusted.com")

      assert :ok = Security.verify_authentication(raw, "zach@x.com", "mx.trusted.com")
    end

    test "with no pin, the top-most header wins even if it doesn't authenticate" do
      raw =
        crlf("""
        Authentication-Results: relay.internal; dmarc=none
        Authentication-Results: mx.trusted.com; dmarc=pass header.from=x.com
        From: zach@x.com

        body
        """)

      assert {:error, :authentication_failed} = Security.verify_authentication(raw, "zach@x.com")
    end
  end

  describe "allowed_sender?/2" do
    test "matches an exact address, case-insensitively" do
      assert Security.allowed_sender?("zach@x.com", ["Zach@X.com"])
      refute Security.allowed_sender?("other@x.com", ["zach@x.com"])
    end

    test "matches a bare-domain entry against the address domain" do
      assert Security.allowed_sender?("anyone@partner.com", ["partner.com"])
      refute Security.allowed_sender?("anyone@evil.com", ["partner.com"])
    end

    test "a bare-domain entry does not silently cover subdomains" do
      refute Security.allowed_sender?("anyone@mail.partner.com", ["partner.com"])
    end

    test "an empty allow-list matches nothing" do
      refute Security.allowed_sender?("zach@x.com", [])
      refute Security.allowed_sender?("zach@x.com", ["", "  "])
    end
  end
end
