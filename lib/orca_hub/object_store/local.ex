defmodule OrcaHub.ObjectStore.Local do
  @moduledoc """
  Local-disk `OrcaHub.ObjectStore` adapter — used in dev/test, and on any
  hub where `ORCA_S3_ENDPOINT` is unset. Stores each object as a plain file
  under the configured root (`ORCA_FILE_STORE_DIR`, default
  `~/.orca_hub/files`), named after `object_key` (which already includes the
  file id, so no collision handling is needed here).
  """

  @behaviour OrcaHub.ObjectStore

  @impl true
  def put(object_key, binary, _content_type) do
    path = object_path(object_key)

    with :ok <- File.mkdir_p(Path.dirname(path)) do
      File.write(path, binary)
    end
  end

  @impl true
  def get(object_key) do
    File.read(object_path(object_key))
  end

  @impl true
  def delete(object_key) do
    case File.rm(object_path(object_key)) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp object_path(object_key) do
    Path.join(root(), object_key)
  end

  defp root do
    Application.get_env(:orca_hub, :file_store_dir) ||
      Path.join(System.user_home!(), ".orca_hub/files")
  end
end
