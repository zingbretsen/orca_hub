defmodule OrcaHub.ObjectStore.S3RangeTest do
  @moduledoc """
  `OrcaHub.ObjectStore.S3.get_range/3` against a local fake S3 endpoint (a
  Bandit-served plug), so the real adapter code path, req_s3 URL building
  and sigv4 signing included, runs in the default suite with no MinIO.
  `s3_test.exs` covers a real bucket under `--only s3`.

  `async: false`: the S3 adapter reads its endpoint from process-wide app
  env, the same key `OrcaHub.ObjectStore.adapter/0` switches on.
  """
  use ExUnit.Case, async: false

  alias OrcaHub.ObjectStore.S3

  defmodule FakeS3 do
    @moduledoc false
    import Plug.Conn

    @body "0123456789"

    def init(opts), do: opts

    # /bucket/honors/<key> answers Range like S3 does; /bucket/ignores/<key>
    # sends the whole object with a 200, like a server that ignores Range.
    def call(%{method: "GET", path_info: ["bucket", mode, _key]} = conn, _opts)
        when mode in ["honors", "ignores"] do
      case {mode, get_req_header(conn, "range")} do
        {"honors", ["bytes=" <> spec]} ->
          [first, last] = spec |> String.split("-") |> Enum.map(&String.to_integer/1)

          if first >= byte_size(@body) do
            send_resp(conn, 416, "")
          else
            last = min(last, byte_size(@body) - 1)
            send_resp(conn, 206, binary_part(@body, first, last - first + 1))
          end

        # Proves the adapter really sent a Range header: without this, its
        # 200-slicing fallback would mask a missing one.
        {"honors", _} ->
          send_resp(conn, 400, "range required")

        _ ->
          send_resp(conn, 200, @body)
      end
    end

    def call(conn, _opts), do: send_resp(conn, 404, "<Error>NoSuchKey</Error>")
  end

  setup do
    server = start_supervised!({Bandit, plug: FakeS3, port: 0, ip: :loopback, startup_log: false})
    {:ok, {_ip, port}} = ThousandIsland.listener_info(server)

    keys = [:s3_endpoint, :s3_bucket, :s3_region, :s3_access_key, :s3_secret_key]
    saved = Map.new(keys, &{&1, Application.fetch_env(:orca_hub, &1)})

    Application.put_env(:orca_hub, :s3_endpoint, "http://127.0.0.1:#{port}")
    Application.put_env(:orca_hub, :s3_bucket, "bucket")
    Application.put_env(:orca_hub, :s3_region, "us-east-1")
    Application.put_env(:orca_hub, :s3_access_key, "test-access")
    Application.put_env(:orca_hub, :s3_secret_key, "test-secret")

    on_exit(fn ->
      for {key, value} <- saved do
        case value do
          {:ok, v} -> Application.put_env(:orca_hub, key, v)
          :error -> Application.delete_env(:orca_hub, key)
        end
      end
    end)

    :ok
  end

  test "a 206 from S3 is returned as-is" do
    assert {:ok, "234"} = S3.get_range("honors/obj.bin", 2, 3)
    assert {:ok, "89"} = S3.get_range("honors/obj.bin", 8, 100)
  end

  test "a 200 (Range ignored) is sliced down to the requested window" do
    assert {:ok, "234"} = S3.get_range("ignores/obj.bin", 2, 3)
    assert {:ok, "89"} = S3.get_range("ignores/obj.bin", 8, 100)
    assert {:error, :range_not_satisfiable} = S3.get_range("ignores/obj.bin", 10, 1)
  end

  test "a 416 is range_not_satisfiable" do
    assert {:error, :range_not_satisfiable} = S3.get_range("honors/obj.bin", 10, 1)
  end

  test "a 404 is not_found" do
    assert {:error, :not_found} = S3.get_range("missing.bin", 0, 1)
  end
end
