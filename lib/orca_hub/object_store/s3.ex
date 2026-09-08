defmodule OrcaHub.ObjectStore.S3 do
  @moduledoc """
  S3-compatible `OrcaHub.ObjectStore` adapter, via the `req_s3` Req plugin.
  Configured from `ORCA_S3_ENDPOINT`/`ORCA_S3_BUCKET`/`ORCA_S3_REGION`/
  `ORCA_S3_ACCESS_KEY`/`ORCA_S3_SECRET_KEY` (see `config/runtime.exs`) —
  selected automatically by `OrcaHub.ObjectStore.adapter/0` when
  `ORCA_S3_ENDPOINT` is set.
  """

  @behaviour OrcaHub.ObjectStore

  @impl true
  def put(object_key, binary, content_type) do
    headers = if content_type, do: [{"content-type", content_type}], else: []

    case Req.put(request(), url: url(object_key), body: binary, headers: headers) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:s3_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def get(object_key) do
    # decode_body: false / raw: true: Req's default decode_body step would
    # otherwise inspect the stored content-type/extension and transparently
    # JSON-decode a ".json" object into a map, or gunzip/untar a
    # ".gz"/".tar"/".zip" one — silently handing back something other than
    # the exact bytes that were stored. Every OrcaHub.ObjectStore caller
    # expects `get/1` to be a byte-identical round trip of `put/1`.
    case Req.get(request(), url: url(object_key), decode_body: false, raw: true) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: status, body: body}} -> {:error, {:s3_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def delete(object_key) do
    case Req.delete(request(), url: url(object_key)) do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:s3_error, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp url(object_key), do: "s3://#{bucket()}/#{object_key}"

  defp request do
    Req.new()
    |> ReqS3.attach(aws_endpoint_url_s3: endpoint())
    |> Req.merge(
      aws_sigv4: [
        access_key_id: config(:s3_access_key),
        secret_access_key: config(:s3_secret_key),
        region: config(:s3_region)
      ]
    )
  end

  defp endpoint, do: config(:s3_endpoint)
  defp bucket, do: config(:s3_bucket)

  defp config(key), do: Application.get_env(:orca_hub, key)
end
