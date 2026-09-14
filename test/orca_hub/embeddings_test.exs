defmodule OrcaHub.EmbeddingsTest do
  @moduledoc """
  Coverage for `OrcaHub.Embeddings` — the hub-only embedding client. The HTTP
  path is stubbed via `Req.Test`; nothing here touches the real endpoint.
  """
  # async: false — tests set the global :embedding_url/:embedding_req_options
  # app env (see config/test.exs, which disables the feature by default).
  use ExUnit.Case, async: false

  alias OrcaHub.Embeddings

  @stub OrcaHub.EmbeddingsStub

  defp vector(dims \\ 1024, fill \\ 0.5), do: List.duplicate(fill, dims)

  defp respond(conn, vectors) do
    data =
      vectors
      |> Enum.with_index()
      |> Enum.map(fn {v, i} -> %{"index" => i, "embedding" => v, "object" => "embedding"} end)

    Req.Test.json(conn, %{"model" => "qwen3-embedding-0.6b", "object" => "list", "data" => data})
  end

  setup do
    Application.put_env(:orca_hub, :embedding_url, "http://embeddings.example.com")
    Application.put_env(:orca_hub, :embedding_req_options, plug: {Req.Test, @stub})

    on_exit(fn ->
      Application.put_env(:orca_hub, :embedding_url, nil)
      Application.delete_env(:orca_hub, :embedding_req_options)
    end)

    :ok
  end

  describe "enabled?/0 and config readers" do
    test "enabled when EMBEDDING_URL is set" do
      assert Embeddings.enabled?()
    end

    test "disabled when EMBEDDING_URL is unset" do
      Application.put_env(:orca_hub, :embedding_url, nil)
      refute Embeddings.enabled?()
    end

    test "model/0 and dims/0 come from config" do
      assert Embeddings.model() == "qwen3-embedding-0.6b"
      assert Embeddings.dims() == 1024
    end
  end

  describe "disabled behavior" do
    setup do
      Application.put_env(:orca_hub, :embedding_url, nil)
      :ok
    end

    test "embed/1 and embed_many/1 return {:error, :disabled} without an HTTP call" do
      assert {:error, :disabled} = Embeddings.embed("hello")
      assert {:error, :disabled} = Embeddings.embed_many(["hello", "world"])
    end

    test "an empty list is still {:ok, []} — no network needed to embed nothing" do
      assert {:ok, []} = Embeddings.embed_many([])
    end
  end

  describe "embed/1" do
    test "returns a single vector" do
      Req.Test.stub(@stub, fn conn -> respond(conn, [vector()]) end)

      assert {:ok, embedding} = Embeddings.embed("hello")
      assert length(embedding) == 1024
    end

    test "sends the configured model and the text as the input" do
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        body = Jason.decode!(raw)
        assert body["model"] == "qwen3-embedding-0.6b"
        assert body["input"] == ["hello"]
        respond(conn, [vector()])
      end)

      assert {:ok, _} = Embeddings.embed("hello")
    end

    test "a blank string is refused before any HTTP call" do
      Req.Test.stub(@stub, fn _conn -> flunk("should not have called the endpoint") end)

      assert {:error, :empty_input} = Embeddings.embed("")
      assert {:error, :empty_input} = Embeddings.embed("   \n ")
    end

    test "a non-string is refused" do
      assert {:error, {:invalid_input, 42}} = Embeddings.embed(42)
    end

    test "a wrong-width vector is rejected rather than handed on to the DB" do
      Req.Test.stub(@stub, fn conn -> respond(conn, [vector(768)]) end)

      assert {:error, {:dimension_mismatch, 768, 1024}} = Embeddings.embed("hello")
    end

    test "an over-context input surfaces the endpoint's 400" do
      Req.Test.stub(@stub, fn conn ->
        conn
        |> Plug.Conn.put_status(400)
        |> Req.Test.json(%{
          "error" => %{"code" => 400, "type" => "exceed_context_size_error"}
        })
      end)

      assert {:error, {:http_error, 400, body}} = Embeddings.embed("a very long thing")
      assert body["error"]["type"] == "exceed_context_size_error"
    end

    test "a transport failure comes back as an error, never a raise" do
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert {:error, {:request_failed, _}} = Embeddings.embed("hello")
    end
  end

  describe "embed_many/1" do
    test "returns one vector per input, in input order" do
      Req.Test.stub(@stub, fn conn ->
        respond(conn, [vector(1024, 0.1), vector(1024, 0.2), vector(1024, 0.3)])
      end)

      assert {:ok, [a, b, c]} = Embeddings.embed_many(["one", "two", "three"])
      assert hd(a) == 0.1
      assert hd(b) == 0.2
      assert hd(c) == 0.3
    end

    test "reorders by the response's index rather than trusting arrival order" do
      Req.Test.stub(@stub, fn conn ->
        Req.Test.json(conn, %{
          "data" => [
            %{"index" => 2, "embedding" => vector(1024, 0.3)},
            %{"index" => 0, "embedding" => vector(1024, 0.1)},
            %{"index" => 1, "embedding" => vector(1024, 0.2)}
          ]
        })
      end)

      assert {:ok, [a, b, c]} = Embeddings.embed_many(["one", "two", "three"])
      assert [hd(a), hd(b), hd(c)] == [0.1, 0.2, 0.3]
    end

    test "batches past 32 inputs across several requests, preserving order" do
      # 70 inputs -> 32 + 32 + 6. Each request echoes a vector whose first
      # element encodes the request's own batch size, so the assertion below
      # proves both the split boundaries and the concatenation order.
      Req.Test.stub(@stub, fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        inputs = Jason.decode!(raw)["input"]
        respond(conn, Enum.map(inputs, fn _ -> vector(1024, length(inputs) * 1.0) end))
      end)

      texts = Enum.map(1..70, &"text #{&1}")
      assert {:ok, vectors} = Embeddings.embed_many(texts)
      assert length(vectors) == 70

      assert vectors |> Enum.map(&hd/1) |> Enum.uniq() == [32.0, 6.0]
      assert vectors |> Enum.map(&hd/1) |> Enum.count(&(&1 == 32.0)) == 64
    end

    test "a failing sub-batch fails the whole call rather than returning a partial" do
      counter = :counters.new(1, [])

      Req.Test.stub(@stub, fn conn ->
        :counters.add(counter, 1, 1)

        if :counters.get(counter, 1) == 1 do
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          inputs = Jason.decode!(raw)["input"]
          respond(conn, Enum.map(inputs, fn _ -> vector() end))
        else
          conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"error" => "boom"})
        end
      end)

      texts = Enum.map(1..40, &"text #{&1}")
      assert {:error, {:http_error, 500, _}} = Embeddings.embed_many(texts)
    end

    test "a blank element anywhere refuses the whole batch (positional mapping would skew)" do
      Req.Test.stub(@stub, fn _conn -> flunk("should not have called the endpoint") end)

      assert {:error, :empty_input} = Embeddings.embed_many(["fine", "", "also fine"])
    end

    test "a non-list and a list with a non-string are both refused" do
      assert {:error, {:invalid_input, :not_all_strings}} = Embeddings.embed_many(["ok", 42])
      assert {:error, {:invalid_input, "nope"}} = Embeddings.embed_many("nope")
    end

    test "a response with the wrong element count is an error, not a silent short list" do
      Req.Test.stub(@stub, fn conn -> respond(conn, [vector()]) end)

      assert {:error, {:count_mismatch, 1, 3}} = Embeddings.embed_many(["a", "b", "c"])
    end

    test "an unexpected response shape is an error, never a raise" do
      Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"unexpected" => true}) end)

      assert {:error, {:unexpected_response, _}} = Embeddings.embed_many(["a"])
    end
  end
end
