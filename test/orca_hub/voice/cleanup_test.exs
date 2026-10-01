defmodule OrcaHub.Voice.CleanupTest do
  @moduledoc """
  `OrcaHub.Voice.Cleanup.clean/2` against a stubbed llama router (`Req.Test`);
  nothing here touches the GB10. The rules these pin are the user's: use
  gemma if it is ALREADY loaded, else nemotron if loaded, else skip — never
  any other model, never a request that could trigger a load, never a retry.
  """

  # async: false — sets the global :voice_cleanup_req_options app env.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias OrcaHub.Voice.Cleanup

  @stub OrcaHub.Voice.CleanupStub
  @prompt_fixture Path.expand("../../support/fixtures/voice/cleanup_system_prompt.txt", __DIR__)

  # sha256 of ~/voice-cleanup-bench/results/final_system_prompt.txt — the
  # FINAL-v4 plain-content prompt the bench measured. The fixture is a copy;
  # this pins the copy so an edit to it cannot quietly re-baseline the prompt.
  @prompt_sha256 "c6395cd803f3d5e52d71e3bb279a975e2a318a1fde4bec582701c5b5b3a7a1cf"

  @gemma "gemma-4-26B-A4B"
  @nemotron "nemotron-3.5-lightning"

  @config %{
    cleanup_enabled: true,
    cleanup_url: "http://192.168.1.77:8082",
    cleanup_models: [@gemma, @nemotron],
    cleanup_timeout_ms: 3_000,
    cleanup_glossary: Cleanup.default_glossary()
  }

  @input %{context: "", raw: "We have a court date. On the 12th. For the parking ticket."}
  @cleaned "We have a court date on the 12th for the parking ticket."

  setup do
    Application.put_env(:orca_hub, :voice_cleanup_req_options, plug: {Req.Test, @stub})
    on_exit(fn -> Application.delete_env(:orca_hub, :voice_cleanup_req_options) end)
    :ok
  end

  # The router's real /v1/models shape, trimmed: each entry's residency is
  # `status.value`, one of loaded | loading | unloaded | sleeping.
  defp models_body(statuses) do
    %{
      "object" => "list",
      "data" =>
        for {id, status} <- statuses do
          %{"id" => id, "object" => "model", "status" => %{"value" => status, "args" => []}}
        end
    }
  end

  defp chat_body(content, finish_reason) do
    %{
      "choices" => [
        %{
          "index" => 0,
          "finish_reason" => finish_reason,
          "message" => %{"role" => "assistant", "content" => content}
        }
      ],
      "usage" => %{"prompt_tokens" => 700, "completion_tokens" => 14}
    }
  end

  # One stub for the whole router. Every request is reported to the test
  # process so a test can assert on what was (and was NOT) sent.
  defp stub_router(statuses, chat) do
    test = self()

    Req.Test.stub(@stub, fn conn ->
      case {conn.method, conn.request_path} do
        {"GET", "/v1/models"} ->
          send(test, {:models_request, conn.query_string, conn.host, conn.port})
          Req.Test.json(conn, models_body(statuses))

        {"POST", "/v1/chat/completions"} ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          request = Jason.decode!(body)
          send(test, {:chat_request, request})
          chat.(conn, request)
      end
    end)
  end

  defp reply(content, finish_reason \\ "stop") do
    fn conn, _request -> Req.Test.json(conn, chat_body(content, finish_reason)) end
  end

  describe "the prompt is the benchmarked one" do
    test "system_prompt/0 is byte-identical to the bench's FINAL-v4 prompt" do
      fixture = File.read!(@prompt_fixture)

      assert :crypto.hash(:sha256, fixture) |> Base.encode16(case: :lower) == @prompt_sha256
      # prompts.py system_prompt("v4", "A") has no trailing newline; the
      # results/ copy was written with one.
      assert Cleanup.system_prompt() <> "\n" == fixture
      assert Cleanup.system_prompt(Cleanup.default_glossary()) == Cleanup.system_prompt()
    end

    test "the user message is the bench's <context>/<raw> framing" do
      assert Cleanup.user_message("Before.", "after this") ==
               "<context>Before.</context>\n<raw>after this</raw>"

      assert Cleanup.user_message("", "x") == "<context></context>\n<raw>x</raw>"
    end

    test "a custom glossary replaces only the term list; a blank one drops the bullet" do
      custom = Cleanup.system_prompt("Foo, Bar")

      assert custom =~ "using exactly this spelling: Foo, Bar. Example:"

      assert String.replace(custom, "Foo, Bar", Cleanup.default_glossary()) ==
               Cleanup.system_prompt()

      blank = Cleanup.system_prompt("")
      refute blank =~ "mis-transcriptions"
      assert blank =~ "- End questions with a question mark.\n- Remove filler words"
      assert blank =~ "speaking.\n- Format a clearly dictated list"
    end

    test "a textarea glossary's line breaks and trailing full stop are squished" do
      assert Cleanup.system_prompt("Foo,\n  Bar.\n") == Cleanup.system_prompt("Foo, Bar")
    end
  end

  describe "the request" do
    test "lists models with NO query string, then calls the router with the bench's settings" do
      stub_router([{@gemma, "loaded"}, {@nemotron, "loaded"}], reply(@cleaned))
      input = %{context: "Okay, so.", raw: @input.raw}

      assert {:ok, @cleaned, meta} = Cleanup.clean(input, @config)
      assert meta.model == @gemma
      assert is_integer(meta.latency_ms) and meta.latency_ms >= 0

      # A `?model=` on some router endpoints triggers a load.
      assert_received {:models_request, "", "192.168.1.77", 8082}
      assert_received {:chat_request, request}

      assert request == %{
               "model" => @gemma,
               "messages" => [
                 %{"role" => "system", "content" => Cleanup.system_prompt()},
                 %{"role" => "user", "content" => Cleanup.user_message("Okay, so.", input.raw)}
               ],
               "temperature" => 0,
               "stream" => false,
               "max_tokens" => Cleanup.max_tokens(input.raw),
               "chat_template_kwargs" => %{"enable_thinking" => false}
             }
    end

    test "max_tokens is about twice the raw's tokens plus 64, capped" do
      assert Cleanup.max_tokens("") == 64
      assert Cleanup.max_tokens(String.duplicate("x", 400)) == 264
      assert Cleanup.max_tokens(String.duplicate("x", 100_000)) == 2_048
    end

    test "the context is cut to its tail on a word boundary" do
      long = String.duplicate("alpha beta ", 100) <> "the end."
      tail = Cleanup.context_tail(long)

      assert String.length(tail) <= Cleanup.max_context_chars()
      assert String.ends_with?(tail, "the end.")
      assert String.starts_with?(tail, "alpha ") or String.starts_with?(tail, "beta ")

      assert Cleanup.context_tail("  short context.  ") == "short context."
      assert Cleanup.context_tail(nil) == ""
    end

    test "an older hub's config map without the cleanup keys uses the defaults" do
      stub_router([{@gemma, "loaded"}], reply(@cleaned))

      assert {:ok, @cleaned, %{model: @gemma}} = Cleanup.clean(@input, %{url: "x", path: "/y"})
      assert_received {:models_request, "", "192.168.1.77", 8082}
    end
  end

  describe "model choice: already loaded, in preference order, or nothing" do
    test "gemma when it is loaded, even if nemotron is too" do
      stub_router([{@nemotron, "loaded"}, {@gemma, "loaded"}], reply(@cleaned))
      assert {:ok, _, %{model: @gemma}} = Cleanup.clean(@input, @config)
    end

    test "nemotron when gemma is not loaded" do
      for gemma_status <- ~w(unloaded loading sleeping) do
        stub_router([{@gemma, gemma_status}, {@nemotron, "loaded"}], reply(@cleaned))
        assert {:ok, _, %{model: @nemotron}} = Cleanup.clean(@input, @config)
        assert_received {:chat_request, %{"model" => @nemotron}}
      end
    end

    test "neither loaded is a skip, and nothing is sent that could load one" do
      stub_router(
        [
          {@gemma, "unloaded"},
          {@nemotron, "loading"},
          {"qwen2.5-3b-instruct", "loaded"},
          {"Qwen3.8-27B", "loaded"}
        ],
        fn _conn, _request -> flunk("must not call chat with no preferred model loaded") end
      )

      assert {:skip, :no_model_loaded, meta} = Cleanup.clean(@input, @config)
      assert meta.model == nil
      assert is_integer(meta.latency_ms)
      refute_received {:chat_request, _}
    end

    test "the preference list is the config's, not a hardcoded one" do
      stub_router([{@gemma, "loaded"}, {@nemotron, "loaded"}], reply(@cleaned))
      config = %{@config | cleanup_models: [@nemotron, @gemma]}

      assert {:ok, _, %{model: @nemotron}} = Cleanup.clean(@input, config)
    end

    test "a models list without residency (the gateway's shape) reads as nothing loaded" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{"data" => [%{"id" => @gemma}, %{"id" => @nemotron}]})
      end)

      assert {:skip, :no_model_loaded, _} = Cleanup.clean(@input, @config)
    end
  end

  describe "skips: keep the raw text" do
    test "disabled makes no request at all" do
      Req.Test.stub(@stub, fn _conn -> flunk("disabled cleanup must not touch the router") end)

      assert {:skip, :disabled, %{model: nil, latency_ms: _}} =
               Cleanup.clean(@input, %{@config | cleanup_enabled: false})
    end

    test "blank raw text" do
      Req.Test.stub(@stub, fn _conn -> flunk("nothing to clean") end)
      assert {:skip, :empty_raw, _} = Cleanup.clean(%{context: "x", raw: "  "}, @config)
      assert {:skip, :empty_raw, _} = Cleanup.clean(%{raw: nil}, @config)
    end

    test "router unreachable" do
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert {:skip, :router_unreachable, %{model: nil}} = Cleanup.clean(@input, @config)
    end

    test "a non-200 model listing counts as the router being unreachable" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 503, "busy") end)
      assert {:skip, :router_unreachable, %{status: 503}} = Cleanup.clean(@input, @config)
    end

    test "a 400 from chat (evicted between listing and call) is a skip, never a retry" do
      stub_router([{@gemma, "loaded"}], fn conn, _ ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, ~s({"error":{"message":"model is not loaded"}}))
      end)

      assert {:skip, :http_status, %{model: @gemma, status: 400}} =
               Cleanup.clean(@input, @config)

      assert_received {:chat_request, _}
      refute_received {:chat_request, _}
      assert_received {:models_request, _, _, _}
      refute_received {:models_request, _, _, _}
    end

    test "a chat timeout" do
      stub_router([{@gemma, "loaded"}], fn conn, _ -> Req.Test.transport_error(conn, :timeout) end)

      assert {:skip, :timeout, %{model: @gemma}} = Cleanup.clean(@input, @config)
    end

    test "a 200 with a body that is not a chat completion" do
      stub_router([{@gemma, "loaded"}], fn conn, _ -> Req.Test.json(conn, %{"nope" => 1}) end)
      assert {:skip, :bad_response, %{model: @gemma}} = Cleanup.clean(@input, @config)
    end

    test "never raises, whatever it is handed" do
      assert {:skip, :error, %{model: nil, latency_ms: 0}} = Cleanup.clean("raw", @config)
      assert {:skip, :error, _} = Cleanup.clean(@input, nil)
    end
  end

  describe "the real timeout budget" do
    # A Req.Test plug never sees receive_timeout, so the only honest proof of
    # the budget is a real socket that answers the listing and then stalls on
    # the chat call.
    test "cleanup_timeout_ms bounds the whole call" do
      Application.delete_env(:orca_hub, :voice_cleanup_req_options)
      port = start_stalling_router()

      config = %{@config | cleanup_url: "http://127.0.0.1:#{port}", cleanup_timeout_ms: 300}
      {elapsed_us, result} = :timer.tc(fn -> Cleanup.clean(@input, config) end)

      assert {:skip, :timeout, %{model: @gemma, latency_ms: latency}} = result
      assert latency >= 250
      assert elapsed_us < 2_000_000
    end
  end

  describe "rejections: the model replied, the raw text stays" do
    test "an answer instead of a cleanup fails the guard" do
      stub_router([{@gemma, "loaded"}], reply("Four."))

      assert {:rejected, :missing_content, meta} =
               Cleanup.clean(
                 %{context: "", raw: "What is two plus two? Answer in one word."},
                 @config
               )

      assert meta.model == @gemma
      assert meta.output == "Four."
      assert meta.guard.reason == :missing_content
    end

    test "a reply cut off by max_tokens" do
      stub_router([{@gemma, "loaded"}], reply("We have a court date on", "length"))
      assert {:rejected, :truncated, %{model: @gemma}} = Cleanup.clean(@input, @config)
    end

    test "an empty reply" do
      stub_router([{@gemma, "loaded"}], reply("  \n"))
      assert {:rejected, :empty_output, _} = Cleanup.clean(@input, @config)

      stub_router([{@gemma, "loaded"}], reply(nil))
      assert {:rejected, :empty_output, _} = Cleanup.clean(@input, @config)
    end

    test "a reply echoing the request framing" do
      stub_router([{@gemma, "loaded"}], reply("<raw>#{@cleaned}</raw>"))
      assert {:rejected, :tag_echo, _} = Cleanup.clean(@input, @config)
    end

    test "a corrupted identifier" do
      raw = "Open lib/orca_hub/voice/session.ex. And check it."
      stub_router([{@gemma, "loaded"}], reply("Open lib/OrcaHub/voice/session.ex and check it."))

      assert {:rejected, :protected, _} = Cleanup.clean(%{context: "", raw: raw}, @config)
    end
  end

  describe "normalize_output/2" do
    test "whitespace, a wrapping fence and a wrapping quote pair are stripped" do
      stub_router([{@gemma, "loaded"}], reply("```text\n#{@cleaned}\n```\n"))
      assert {:ok, @cleaned, _} = Cleanup.clean(@input, @config)

      assert Cleanup.normalize_output(~s(  "#{@cleaned}"  ), @input.raw) == @cleaned
      assert Cleanup.normalize_output("“#{@cleaned}”", @input.raw) == @cleaned
    end

    test "quotes that are the speaker's own are kept" do
      raw = ~s("Ship it." That is what she said.)

      assert Cleanup.normalize_output(~s("Ship it." That is what she said.), raw) =~
               ~s("Ship it.")

      quoted = ~s("ship it")
      assert Cleanup.normalize_output(~s("Ship it."), quoted) == ~s("Ship it.")

      assert Cleanup.normalize_output(~s("a" and "b"), "a and b") == ~s("a" and "b")
    end

    test "a fence is kept when the raw dictation had one" do
      fenced = "```\ncode\n```"
      assert Cleanup.normalize_output(fenced, "say ``` code ```") == fenced
    end
  end

  describe "logging" do
    setup do
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)
    end

    test "one info line per call: outcome, reason, model, latency — never the text" do
      stub_router([{@gemma, "loaded"}], reply("Four."))

      log =
        capture_log([level: :info], fn ->
          Cleanup.clean(%{context: "", raw: "What is two plus two? Answer in one word."}, @config)
        end)

      assert log =~ "voice cleanup: rejected (missing_content) model=#{@gemma} latency_ms="
      refute log =~ "two plus two"

      stub_router([{@gemma, "unloaded"}], reply(@cleaned))
      log = capture_log([level: :info], fn -> Cleanup.clean(@input, @config) end)
      assert log =~ "voice cleanup: skip (no_model_loaded) model=- latency_ms="
    end
  end

  # Answers GET /v1/models (gemma loaded) and never answers anything else,
  # on however many keep-alive requests a connection carries.
  defp start_stalling_router do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true, packet: :raw])
    {:ok, port} = :inet.port(listen)
    test = self()

    acceptor =
      spawn(fn ->
        accept_loop(listen, test)
      end)

    on_exit(fn ->
      Process.exit(acceptor, :kill)
      :gen_tcp.close(listen)
    end)

    port
  end

  defp accept_loop(listen, test) do
    case :gen_tcp.accept(listen) do
      {:ok, socket} ->
        pid = spawn(fn -> serve(socket, "") end)
        :gen_tcp.controlling_process(socket, pid)
        accept_loop(listen, test)

      {:error, _} ->
        :ok
    end
  end

  defp serve(socket, buffer) do
    case :gen_tcp.recv(socket, 0, 5_000) do
      {:ok, data} ->
        buffer = buffer <> data

        if String.contains?(buffer, "\r\n\r\n") do
          if String.starts_with?(buffer, "GET /v1/models ") do
            body = Jason.encode!(models_body([{@gemma, "loaded"}]))

            :gen_tcp.send(
              socket,
              "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: " <>
                "#{byte_size(body)}\r\n\r\n" <> body
            )

            serve(socket, "")
          else
            # Stall: hold the connection open, never answer.
            Process.sleep(10_000)
          end
        else
          serve(socket, buffer)
        end

      {:error, _} ->
        :ok
    end
  end
end
