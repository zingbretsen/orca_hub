defmodule OrcaHubWeb.VoiceChannelTest do
  @moduledoc """
  The `voice:<session_id>` channel against the wire contract in
  `voice_mode_spec.md` section 8.1 — join replies, the binary segment frame,
  the client event set, and one full happy path from PCM to `"sent"`.

  Two seams stand in for the real world:

    * ASR — `Application.put_env(:orca_hub, :asr_req_options, plug:
      {Req.Test, stub})`, the same seam `OrcaHub.Voice.ASRTest` uses, in
      SHARED ownership mode because the channel makes its calls from a
      `Task` rather than the test process.
    * SENDING — `:voice_sender`, a 4-arity injection point on
      `Cluster.send_message/4`. DECISION: the real call goes through
      `SessionHeartbeat`, a hub GenServer that would queue against the
      shared dev DB and can start a real CLI runner; asserting on the
      injected call is a sharper check of what this channel does (right
      node, right session, right text, `:queue` and never `:interrupt`)
      than reading a row back out afterwards.
  """
  # async: false — VoiceChannel.join/3 resolves the session through HubRPC,
  # which goes via :erpc even for the local node, and both app-env seams
  # above are global.
  use OrcaHub.DataCase, async: false

  import Phoenix.ChannelTest

  alias OrcaHub.{Projects, Sessions}
  alias OrcaHubWeb.{UserSocket, VoiceChannel}

  @endpoint OrcaHubWeb.Endpoint

  @stub OrcaHubWeb.VoiceChannelStub

  # A transcript that is one dictated line plus a spoken send.
  @transcript "let's ship it orca send"

  setup do
    Req.Test.set_req_test_to_shared()

    Req.Test.stub(@stub, fn conn ->
      Req.Test.json(conn, %{
        "text" => @transcript,
        "language" => "en",
        "duration" => 2.4,
        "model" => "large-v3-turbo",
        "elapsed_seconds" => 0.61
      })
    end)

    Application.put_env(:orca_hub, :asr_req_options, plug: {Req.Test, @stub})

    test_pid = self()

    Application.put_env(:orca_hub, :voice_sender, fn node, session_id, text, delivery ->
      send(test_pid, {:voice_send, node, session_id, text, delivery})
      :ok
    end)

    on_exit(fn ->
      Application.delete_env(:orca_hub, :asr_req_options)
      Application.delete_env(:orca_hub, :voice_sender)
    end)

    dir = Path.join(System.tmp_dir!(), "voice_channel_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{
        name: "voice-channel-test-#{System.unique_integer([:positive])}",
        directory: dir,
        node: to_string(node())
      })

    {:ok, session} =
      Sessions.create_session(%{
        directory: dir,
        project_id: project.id,
        runner_node: to_string(node())
      })

    {:ok, session: session, project: project, dir: dir}
  end

  # -- helpers ---------------------------------------------------------------

  defp join(session_id) do
    subscribe_and_join(socket(UserSocket, nil, %{}), VoiceChannel, "voice:#{session_id}", %{})
  end

  # Joins and waits out the warm-up ping's state push, so a test's own
  # assertions start from a known `listening` baseline. (The join REPLY
  # carries `warming`; the first pushed state is the warm-up's result.)
  defp join_warm!(session_id) do
    {:ok, reply, socket} = join(session_id)
    assert_push "state", %{status: "listening", warm: true}, 5_000
    {reply, socket}
  end

  defp await_release(session_id, attempts \\ 50) do
    cond do
      Registry.lookup(OrcaHub.SessionViewersRegistry, session_id) == [] ->
        true

      attempts == 0 ->
        false

      true ->
        Process.sleep(20)
        await_release(session_id, attempts - 1)
    end
  end

  defp pcm(samples), do: :binary.copy(<<0, 0>>, samples)

  defp segment(seq, samples, opts \\ []) do
    pcm = Keyword.get(opts, :pcm, pcm(samples))
    flags = Keyword.get(opts, :flags, 0)
    start_sample = Keyword.get(opts, :start_sample, 0)

    <<"OVS1", seq::little-32, start_sample::little-32, samples::little-32, flags::little-32,
      pcm::binary>>
  end

  # -- join ------------------------------------------------------------------

  describe "join/3" do
    test "replies ok with the initial snapshot and claims the voice slot", %{session: session} do
      {:ok, reply, socket} = join(session.id)

      assert %{
               state: %{
                 status: "warming",
                 draft: "",
                 muted: false,
                 warm: false,
                 pending: 0,
                 arming_ms: nil,
                 error: nil
               }
             } = reply

      assert socket.assigns.session_id == session.id
      assert socket.assigns.runner_node == node()

      assert [{_pid, %{voice: true}}] =
               Registry.lookup(OrcaHub.SessionViewersRegistry, session.id)

      assert_push "state", %{status: "listening", warm: true}, 5_000
    end

    test "the warm-up ping runs without blocking the join reply", %{session: session} do
      {:ok, _reply, _socket} = join(session.id)

      assert_push "state", %{status: "listening", warm: true}, 2_000
    end

    test "a warm-up failure surfaces as an error state", %{session: session} do
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      {:ok, _reply, _socket} = join(session.id)

      assert_push "state", %{status: "error", warm: false, error: error}, 2_000
      assert error =~ "ASR unreachable"
      assert error =~ "connection refused"
    end

    test "an unknown session id is not_found" do
      assert {:error, %{reason: "not_found"}} = join(Ecto.UUID.generate())
    end

    test "an archived session is refused", %{session: session} do
      {:ok, session} =
        Sessions.update_session(session, %{archived_at: DateTime.utc_now()})

      assert {:error, %{reason: "archived"}} = join(session.id)
    end

    test "a session whose node is offline is refused, never re-routed", %{
      project: project,
      dir: dir
    } do
      {:ok, offline} =
        Sessions.create_session(%{
          directory: dir,
          project_id: project.id,
          runner_node: "orca@definitely-not-connected"
        })

      assert {:error, %{reason: "node_unavailable"}} = join(offline.id)
    end

    test "a second join for the same session is refused as voice_owned", %{session: session} do
      {_reply, _socket} = join_warm!(session.id)

      assert {:error, %{reason: "voice_owned"}} = join(session.id)
    end

    test "the claim is released when the channel process exits", %{session: session} do
      {:ok, _reply, socket} = join(session.id)
      ref = Process.monitor(socket.channel_pid)
      # ChannelTest links the channel to the test process; leaving would
      # otherwise take the test down with `shutdown: :left`.
      Process.unlink(socket.channel_pid)

      leave(socket)
      assert_receive {:DOWN, ^ref, :process, _pid, _reason}, 1_000

      # The registry drops the entry in its own partition process, which can
      # lag our monitor by a scheduling quantum — so poll rather than
      # asserting on the first read.
      assert await_release(session.id), "the voice claim was never released"

      assert {_reply, _socket} = join_warm!(session.id)
    end
  end

  # -- segments --------------------------------------------------------------

  describe "the binary segment frame" do
    test "a bad magic is reported as an error result rather than crashing", %{session: session} do
      {_reply, socket} = join_warm!(session.id)

      bad = <<"XXXX", 1::little-32, 0::little-32, 16_000::little-32, 0::little-32>> <> pcm(16_000)
      push(socket, "segment", {:binary, bad})

      assert_push "segment_result", %{seq: 0, action: "error", detail: detail}, 1_000
      assert detail =~ "OVS1"
      assert Process.alive?(socket.channel_pid)
    end

    test "a header/payload length mismatch is reported the same way", %{session: session} do
      {_reply, socket} = join_warm!(session.id)

      lying = segment(1, 16_000, pcm: pcm(400))
      push(socket, "segment", {:binary, lying})

      assert_push "segment_result", %{seq: 0, action: "error", detail: detail}, 1_000
      assert detail =~ "length mismatch"
      assert Process.alive?(socket.channel_pid)
    end

    test "a segment arriving while the mic is muted is dropped", %{session: session} do
      {_reply, socket} = join_warm!(session.id)

      push(socket, "mic", %{"muted" => true, "reason" => "tts"})
      assert_push "state", %{muted: true}, 1_000

      push(socket, "segment", {:binary, segment(1, 16_000)})

      assert_push "segment_result", %{seq: 1, action: "dropped_muted"}, 1_000
      assert_push "state", %{pending: 0}, 1_000
      refute_receive {:voice_send, _, _, _, _}, 200
    end
  end

  # -- client events ---------------------------------------------------------

  describe "client events" do
    test "draft_edit replaces the draft", %{session: session} do
      {_reply, socket} = join_warm!(session.id)

      push(socket, "draft_edit", %{"text" => "typed by hand"})

      assert_push "state", %{draft: "typed by hand", arming_ms: nil}, 1_000
    end

    test "send_now on an empty draft is a no-op", %{session: session} do
      {_reply, socket} = join_warm!(session.id)

      push(socket, "send_now", %{})

      assert_push "state", %{draft: "", status: status}, 1_000
      refute status == "sending"
      refute_receive {:voice_send, _, _, _, _}, 200
    end

    test "send_now on a hand-typed draft asks the client to send it", %{session: session} do
      {_reply, socket} = join_warm!(session.id)

      push(socket, "draft_edit", %{"text" => "ship it"})
      assert_push "state", %{draft: "ship it"}, 1_000

      push(socket, "send_now", %{})

      # Spec 8.2: the request goes to the browser, not to Cluster.
      assert_push "send_request", %{text: "ship it"}, 1_000
      assert_push "state", %{status: "sending"}, 1_000
      refute_receive {:voice_send, _, _, _, _}, 200
    end

    test "cancel clears the draft", %{session: session} do
      {_reply, socket} = join_warm!(session.id)

      push(socket, "draft_edit", %{"text" => "never mind"})
      assert_push "state", %{draft: "never mind"}, 1_000

      push(socket, "cancel", %{})
      assert_push "state", %{draft: ""}, 1_000
    end

    test "speech_start cancels an open arming window", %{session: session} do
      {_reply, socket} = join_warm!(session.id)

      push(socket, "segment", {:binary, segment(1, 16_000)})
      assert_push "segment_result", %{seq: 1, action: "send", intent: "send"}, 2_000
      assert_push "state", %{status: "arming", arming_ms: ms}, 1_000
      assert ms > 0

      push(socket, "speech_start", %{})
      assert_push "state", %{arming_ms: nil, draft: "let's ship it"}, 1_000

      # The arming timer still fires; it must not send anything.
      refute_receive {:voice_send, _, _, _, _}, 2_000
    end
  end

  # -- the happy path --------------------------------------------------------

  describe "the full SEND path" do
    test "PCM in, transcript, strip, arming window, send_request out", %{session: session} do
      {_reply, socket} = join_warm!(session.id)

      push(socket, "composer", %{"present" => true})
      push(socket, "speech_start", %{})
      push(socket, "segment", {:binary, segment(1, 16_000)})

      assert_push "segment_result",
                  %{
                    seq: 1,
                    text: @transcript,
                    intent: "send",
                    action: "send",
                    score: score,
                    elapsed_seconds: 0.61,
                    duration: 2.4
                  },
                  2_000

      assert score >= 0.85

      # The command tokens are stripped out of the draft before it is sent.
      assert_push "state", %{status: "arming", draft: "let's ship it", arming_ms: ms}, 1_000
      assert ms > 0 and ms <= 1500

      # ...and after the window expires with no further speech, the CLIENT is
      # asked to run it through the composer — ORCAHUB3-86. The server itself
      # delivers nothing.
      assert_push "send_request", %{text: "let's ship it"}, 3_000
      assert_push "state", %{status: "sending"}, 1_000
      refute_receive {:voice_send, _, _, _, _}, 200

      # The composer's LiveView pushed clear-prompt: delivery succeeded, with
      # whatever uploads were staged alongside it.
      push(socket, "sent_ack", %{})

      assert_push "sent", %{text: "let's ship it"}, 1_000
      assert_push "state", %{status: "listening", draft: "", arming_ms: nil}, 1_000
    end

    test "a composer failure keeps the draft and shows the reason", %{session: session} do
      {_reply, socket} = join_warm!(session.id)

      push(socket, "composer", %{"present" => true})
      push(socket, "draft_edit", %{"text" => "ship it"})
      push(socket, "send_now", %{})
      assert_push "send_request", %{text: "ship it"}, 1_000

      push(socket, "send_failed", %{"reason" => "Session is busy"})

      assert_push "state", %{status: "error", error: "Session is busy", draft: "ship it"}, 1_000
      refute_receive {:voice_send, _, _, _, _}, 200
    end

    test "send_failed with no reason still says something useful", %{session: session} do
      {_reply, socket} = join_warm!(session.id)

      push(socket, "draft_edit", %{"text" => "ship it"})
      push(socket, "send_now", %{})
      assert_push "send_request", %{text: "ship it"}, 1_000

      push(socket, "send_failed", %{})

      assert_push "state", %{status: "error", error: error}, 1_000
      assert error =~ "could not send"
    end

    test "with no composer on the page the server delivers it itself", %{session: session} do
      {_reply, socket} = join_warm!(session.id)

      # The user is on /queue: the bar has its own draft box and no composer.
      push(socket, "composer", %{"present" => false})
      push(socket, "draft_edit", %{"text" => "ship it"})
      push(socket, "send_now", %{})
      assert_push "send_request", %{text: "ship it"}, 1_000

      push(socket, "send_direct", %{})

      assert_receive {:voice_send, sent_node, sent_id, "ship it", :queue}, 1_000
      assert sent_node == node()
      assert sent_id == session.id
      assert_push "sent", %{text: "ship it"}, 1_000
      assert_push "state", %{status: "listening", draft: ""}, 1_000
    end

    @tag timeout: 30_000
    test "a client that never answers falls back to a direct send after 5 s",
         %{session: session} do
      {_reply, socket} = join_warm!(session.id)

      # No "composer" event was ever sent, so the fallback is allowed to
      # deliver — the client is simply not on a session page.
      push(socket, "draft_edit", %{"text" => "ship it"})
      push(socket, "send_now", %{})
      assert_push "send_request", %{text: "ship it"}, 1_000

      assert_receive {:voice_send, _node, _id, "ship it", :queue}, 8_000
      assert_push "sent", %{text: "ship it"}, 1_000
    end
  end
end
