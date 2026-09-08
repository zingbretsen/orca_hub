defmodule OrcaHub.ObjectStore.S3Test do
  # Hits a real S3-compatible endpoint — excluded by default (see
  # test/test_helper.exs), and a no-op unless ORCA_S3_ENDPOINT is actually
  # set even under `mix test --only s3` (a sibling worker is provisioning
  # MinIO separately — see ORCAHUB3-72).
  use ExUnit.Case, async: false

  @tag :s3
  test "put/1, get/1, delete/1 round-trip against the configured bucket" do
    if System.get_env("ORCA_S3_ENDPOINT") do
      key = "s3_test/#{System.unique_integer([:positive])}/roundtrip.txt"

      assert :ok = OrcaHub.ObjectStore.S3.put(key, "hello from s3 test", "text/plain")
      assert {:ok, "hello from s3 test"} = OrcaHub.ObjectStore.S3.get(key)
      assert :ok = OrcaHub.ObjectStore.S3.delete(key)
      assert {:error, :not_found} = OrcaHub.ObjectStore.S3.get(key)
    else
      :ok
    end
  end
end
