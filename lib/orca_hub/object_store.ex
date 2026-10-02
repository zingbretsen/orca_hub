defmodule OrcaHub.ObjectStore do
  @moduledoc """
  Behaviour for the byte-storage side of the cross-node file store (see
  `OrcaHub.Files` for the full design). Every implementation stores/retrieves
  a binary blob addressed by an opaque `object_key` string — no other
  metadata concerns (visibility, quota, size caps) belong here, those live
  in `OrcaHub.Files`.

  Only ever called from hub-side code (`OrcaHub.Files`) — object store
  credentials (S3 access/secret keys) must never leave the hub, so an agent
  node reaches this only indirectly, via `OrcaHub.HubRPC`.
  """

  @callback put(object_key :: String.t(), binary :: binary(), content_type :: String.t() | nil) ::
              :ok | {:error, term()}
  @callback get(object_key :: String.t()) :: {:ok, binary()} | {:error, term()}

  @doc """
  `length` bytes starting at byte `offset` — backs HTTP Range on artifact
  assets (`<video>` on iOS Safari won't play without 206s), so a seek reads
  only the requested window, not the whole object. May return FEWER bytes
  than asked if the object ends first; `{:error, :range_not_satisfiable}`
  when `offset` is at or past the end.
  """
  @callback get_range(
              object_key :: String.t(),
              offset :: non_neg_integer(),
              length :: pos_integer()
            ) :: {:ok, binary()} | {:error, term()}

  @callback delete(object_key :: String.t()) :: :ok | {:error, term()}

  @doc """
  Resolves the configured adapter: `OrcaHub.ObjectStore.S3` iff
  `ORCA_S3_ENDPOINT` is set, else `OrcaHub.ObjectStore.Local`.
  """
  def adapter do
    if Application.get_env(:orca_hub, :s3_endpoint) do
      OrcaHub.ObjectStore.S3
    else
      OrcaHub.ObjectStore.Local
    end
  end

  def put(object_key, binary, content_type), do: adapter().put(object_key, binary, content_type)
  def get(object_key), do: adapter().get(object_key)

  def get_range(object_key, offset, length),
    do: adapter().get_range(object_key, offset, length)

  def delete(object_key), do: adapter().delete(object_key)
end
