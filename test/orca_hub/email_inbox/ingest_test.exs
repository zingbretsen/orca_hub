defmodule OrcaHub.EmailInbox.IngestTest do
  use ExUnit.Case, async: true

  alias OrcaHub.EmailInbox.Ingest
  alias OrcaHub.EmailInboxes.EmailInbox
  alias OrcaHub.Triggers.Trigger

  @inbox %EmailInbox{name: "test inbox", trusted_authserv_id: nil}

  defp crlf(text), do: String.replace(text, ~r/\r?\n/, "\r\n")

  defp trigger(overrides \\ %{}) do
    struct(
      %Trigger{
        id: Ecto.UUID.generate(),
        name: "catch-all",
        sender_allowlist: ["zach@x.com"],
        to_address: nil,
        subject_pattern: nil
      },
      overrides
    )
  end

  defp message(opts \\ []) do
    from = Keyword.get(opts, :from, "zach@x.com")
    to = Keyword.get(opts, :to, "ops@example.com")
    subject = Keyword.get(opts, :subject, "hello there")

    auth =
      Keyword.get(
        opts,
        :auth,
        "Authentication-Results: mx.trusted.com; dmarc=pass header.from=x.com\n"
      )

    body = Keyword.get(opts, :body, "This is the body.\n")

    crlf("""
    #{auth}From: #{from}
    To: #{to}
    Subject: #{subject}
    Message-Id: <abc123@x.com>
    In-Reply-To: <prior@x.com>

    #{body}
    """)
  end

  describe "decide/3 — sender authentication" do
    test "accepts an authenticated, allow-listed sender" do
      assert {:accept, trigger, payload} = Ingest.decide(@inbox, message(), [trigger()])
      assert trigger.name == "catch-all"
      # Atom key/value: a JSON webhook body can never spell this, so it can't
      # borrow the email prompt's "sender was verified" framing.
      assert payload.source == :email
      assert payload["from"] == "zach@x.com"
      assert payload["subject"] == "hello there"
      assert payload["message_id"] == "<abc123@x.com>"
      assert payload["in_reply_to"] == "<prior@x.com>"
      assert payload["body"] =~ "This is the body."
    end

    test "rejects a message with no Authentication-Results header" do
      assert {:reject, :no_authentication_results} =
               Ingest.decide(@inbox, message(auth: ""), [trigger()])
    end

    test "rejects dmarc=fail" do
      raw =
        message(auth: "Authentication-Results: mx.trusted.com; dmarc=fail header.from=x.com\n")

      assert {:reject, :authentication_failed} = Ingest.decide(@inbox, raw, [trigger()])
    end

    test "rejects dmarc=pass claimed for the wrong domain" do
      raw =
        message(auth: "Authentication-Results: mx.trusted.com; dmarc=pass header.from=evil.com\n")

      assert {:reject, :authentication_failed} = Ingest.decide(@inbox, raw, [trigger()])
    end

    test "uses the TOP-MOST Authentication-Results header, not a spoofed one below it" do
      raw =
        message(
          from: "attacker@evil.com",
          auth: """
          Authentication-Results: mx.trusted.com; dmarc=fail header.from=evil.com
          Authentication-Results: totally.legit.example; dmarc=pass header.from=evil.com
          """
        )

      assert {:reject, :authentication_failed} =
               Ingest.decide(@inbox, raw, [trigger(%{sender_allowlist: ["attacker@evil.com"]})])
    end

    test "matches the addr-spec, not a display name impersonating an allow-listed address" do
      raw = message(from: ~s("zach@x.com" <attacker@evil.com>))

      # Authenticated as evil.com (its real domain), and evil.com is not
      # allow-listed — the "zach@x.com" display name buys nothing.
      raw =
        String.replace(
          raw,
          "dmarc=pass header.from=x.com",
          "dmarc=pass header.from=evil.com"
        )

      assert {:reject, :sender_not_allowed} = Ingest.decide(@inbox, raw, [trigger()])
    end
  end

  describe "decide/3 — allow-list" do
    test "rejects an authenticated sender who is not on the trigger's allow-list" do
      raw = message(from: "stranger@x.com")
      assert {:reject, :sender_not_allowed} = Ingest.decide(@inbox, raw, [trigger()])
    end

    test "accepts a sender matched by a bare-domain allow-list entry" do
      raw = message(from: "someone@x.com")

      assert {:accept, _, _} =
               Ingest.decide(@inbox, raw, [trigger(%{sender_allowlist: ["x.com"]})])
    end

    test "rejects when there are no triggers at all" do
      assert {:reject, :sender_not_allowed} = Ingest.decide(@inbox, message(), [])
    end
  end

  describe "decide/3 — routing across triggers sharing one inbox" do
    test "picks the trigger whose to_address matches" do
      triggers = [
        trigger(%{name: "invoices", to_address: "invoices@example.com"}),
        trigger(%{name: "support", to_address: "support@example.com"})
      ]

      raw = message(to: "support@example.com")
      assert {:accept, picked, _} = Ingest.decide(@inbox, raw, triggers)
      assert picked.name == "support"
    end

    test "picks the trigger whose subject_pattern matches, case-insensitively" do
      triggers = [
        trigger(%{name: "invoices", subject_pattern: "invoice"}),
        trigger(%{name: "alerts", subject_pattern: "ALERT"})
      ]

      raw = message(subject: "Weekly alert digest")
      assert {:accept, picked, _} = Ingest.decide(@inbox, raw, triggers)
      assert picked.name == "alerts"
    end

    test "a more specific trigger beats a catch-all sharing the same inbox" do
      triggers = [
        trigger(%{name: "catch-all"}),
        trigger(%{name: "invoices", subject_pattern: "invoice"})
      ]

      assert {:accept, picked, _} =
               Ingest.decide(@inbox, message(subject: "Your invoice"), triggers)

      assert picked.name == "invoices"

      assert {:accept, fallback, _} =
               Ingest.decide(@inbox, message(subject: "just saying hi"), triggers)

      assert fallback.name == "catch-all"
    end

    test "rejects when the sender is allowed but no trigger's routing rules match" do
      triggers = [trigger(%{name: "invoices", subject_pattern: "invoice"})]

      assert {:reject, :no_matching_trigger} =
               Ingest.decide(@inbox, message(subject: "unrelated"), triggers)
    end
  end

  describe "decide/3 — trusted_authserv_id pinning" do
    test "refuses an Authentication-Results header from an unpinned authserv-id" do
      inbox = %EmailInbox{name: "pinned", trusted_authserv_id: "mx.trusted.com"}

      raw =
        message(auth: "Authentication-Results: sender.example; dmarc=pass header.from=x.com\n")

      assert {:reject, :untrusted_authserv_id} = Ingest.decide(inbox, raw, [trigger()])
    end

    test "accepts when the pinned authserv-id is the one that authenticated" do
      inbox = %EmailInbox{name: "pinned", trusted_authserv_id: "mx.trusted.com"}
      assert {:accept, _, _} = Ingest.decide(inbox, message(), [trigger()])
    end
  end

  describe "decide/3 — body handling" do
    test "prefers text/plain over text/html" do
      raw =
        crlf("""
        Authentication-Results: mx.trusted.com; dmarc=pass header.from=x.com
        From: zach@x.com
        To: ops@example.com
        Subject: multipart
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="BOUND"

        --BOUND
        Content-Type: text/plain

        the plain text part
        --BOUND
        Content-Type: text/html

        <p>the html part</p>
        --BOUND--
        """)

      assert {:accept, _, payload} = Ingest.decide(@inbox, raw, [trigger()])
      assert payload["body"] =~ "the plain text part"
      refute payload["body"] =~ "html part"
    end

    test "strips quoted reply chains" do
      body = """
      Here is my actual reply.

      On Tue, Aug 12, 2026 at 9:00 AM Someone <s@y.com> wrote:
      > the entire prior thread
      > goes here
      """

      assert {:accept, _, payload} = Ingest.decide(@inbox, message(body: body), [trigger()])
      assert payload["body"] =~ "Here is my actual reply."
      refute payload["body"] =~ "entire prior thread"
    end

    test "caps an enormous body with a [truncated] marker" do
      raw = message(body: String.duplicate("a", 40_000))
      assert {:accept, _, payload} = Ingest.decide(@inbox, raw, [trigger()])
      assert payload["body"] =~ "[truncated]"
      assert byte_size(payload["body"]) < 20_000
    end
  end

  describe "decide/3 — attachments" do
    defp with_attachment(data, filename) do
      crlf("""
      Authentication-Results: mx.trusted.com; dmarc=pass header.from=x.com
      From: zach@x.com
      To: ops@example.com
      Subject: with attachment
      MIME-Version: 1.0
      Content-Type: multipart/mixed; boundary="BOUND"

      --BOUND
      Content-Type: text/plain

      see attached
      --BOUND
      Content-Type: application/octet-stream
      Content-Disposition: attachment; filename="#{filename}"
      Content-Transfer-Encoding: base64

      #{Base.encode64(data)}
      --BOUND--
      """)
    end

    test "carries decoded attachment bytes under a sanitized display filename" do
      raw = with_attachment("secret-report", "../../etc/passwd")

      assert {:accept, _, payload} = Ingest.decide(@inbox, raw, [trigger()])
      assert [%{"filename" => "passwd", "data" => "secret-report"}] = payload["attachments"]
    end

    test "drops attachments over the size cap but still processes the email" do
      previous = Application.get_env(:orca_hub, :email_max_attachment_bytes)
      Application.put_env(:orca_hub, :email_max_attachment_bytes, 16)

      on_exit(fn ->
        if previous do
          Application.put_env(:orca_hub, :email_max_attachment_bytes, previous)
        else
          Application.delete_env(:orca_hub, :email_max_attachment_bytes)
        end
      end)

      raw = with_attachment(String.duplicate("x", 1_000), "big.bin")

      assert {:accept, _, payload} = Ingest.decide(@inbox, raw, [trigger()])
      assert payload["attachments"] == []
      assert payload["body"] =~ "see attached"
    end
  end

  describe "decide/3 — hostile input" do
    test "never raises on garbage input" do
      for raw <- ["", "\r\n\r\n", "not an email at all", String.duplicate("\x00", 100)] do
        assert {:reject, _reason} = Ingest.decide(@inbox, raw, [trigger()])
      end
    end
  end

  describe "ingest/3" do
    test "returns {:rejected, reason} without firing anything on a rejected message" do
      assert {:rejected, :no_authentication_results} =
               Ingest.ingest(@inbox, message(auth: ""), [trigger()])
    end

    test "does not raise on a malformed message" do
      assert {:rejected, _} = Ingest.ingest(@inbox, "garbage", [trigger()])
    end
  end

  describe "sanitize_filename/1" do
    test "neutralizes traversal attempts" do
      assert Ingest.sanitize_filename("../../etc/passwd") == "passwd"
      assert Ingest.sanitize_filename("/etc/passwd") == "passwd"
      assert Ingest.sanitize_filename("..\\..\\windows\\system32\\x") == "x"
      assert Ingest.sanitize_filename("....//....//etc/shadow") == "shadow"
    end

    test "collapses degenerate names to a placeholder" do
      assert Ingest.sanitize_filename("..") == "attachment"
      assert Ingest.sanitize_filename(".") == "attachment"
      assert Ingest.sanitize_filename("") == "attachment"
      assert Ingest.sanitize_filename("   ") == "attachment"
      assert Ingest.sanitize_filename("/") == "attachment"
      assert Ingest.sanitize_filename(nil) == "attachment"
    end

    test "leaves an ordinary filename alone" do
      assert Ingest.sanitize_filename("invoice.pdf") == "invoice.pdf"
      assert Ingest.sanitize_filename("Q3 report (final).xlsx") == "Q3 report (final).xlsx"
    end
  end

  describe "write_attachments/2" do
    setup do
      dir = Path.join(System.tmp_dir!(), "orca_email_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{dir: dir}
    end

    test "writes under .orca_email_attachments with a GENERATED name", %{dir: dir} do
      paths =
        Ingest.write_attachments(dir, [
          %{"filename" => "invoice.pdf", "data" => "pdf-bytes"},
          %{"filename" => "notes.txt", "data" => "text-bytes"}
        ])

      assert [first, second] = paths
      assert Path.basename(first) == "attachment_1.pdf"
      assert Path.basename(second) == "attachment_2.txt"
      assert Path.dirname(first) == Path.join(dir, ".orca_email_attachments")
      assert File.read!(first) == "pdf-bytes"
      assert File.read!(second) == "text-bytes"
    end

    test "a traversal filename cannot escape the attachments directory", %{dir: dir} do
      escape_target = Path.join(Path.dirname(dir), "pwned")
      on_exit(fn -> File.rm_rf(escape_target) end)

      assert [path] =
               Ingest.write_attachments(dir, [
                 %{"filename" => "../../pwned", "data" => "owned"}
               ])

      assert Path.dirname(path) == Path.join(dir, ".orca_email_attachments")
      refute File.exists?(escape_target)
    end

    test "returns [] for no attachments", %{dir: dir} do
      assert Ingest.write_attachments(dir, []) == []
    end
  end
end
