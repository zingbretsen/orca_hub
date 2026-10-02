defmodule OrcaHubWeb.ArtifactURLTest do
  use ExUnit.Case, async: true

  alias OrcaHubWeb.ArtifactURL

  @id "0f6b2a9e-4c3d-4e5f-8a7b-1c2d3e4f5a6b"

  test "a minted token verifies back to its artifact id" do
    assert {:ok, @id} = @id |> ArtifactURL.mint() |> ArtifactURL.verify()
  end

  test "signed_at is floored to the hour: every mint in one hour yields the same token" do
    hour = div(System.system_time(:second), 3600) * 3600

    assert ArtifactURL.mint(@id, now: hour) == ArtifactURL.mint(@id, now: hour + 3599)
    refute ArtifactURL.mint(@id, now: hour) == ArtifactURL.mint(@id, now: hour + 3600)
  end

  test "a token older than max_age is rejected" do
    old = System.system_time(:second) - ArtifactURL.max_age_seconds() - 3600
    assert :error = @id |> ArtifactURL.mint(now: old) |> ArtifactURL.verify()
  end

  test "a tampered token, a garbage token and nil are rejected" do
    # Another artifact's payload under this token's signature.
    [proto, _payload, sig] = String.split(ArtifactURL.mint(@id), ".")
    [_, other_payload, _] = String.split(ArtifactURL.mint(Ecto.UUID.generate()), ".")

    assert :error = ArtifactURL.verify(Enum.join([proto, other_payload, sig], "."))
    assert :error = ArtifactURL.verify("not-a-token")
    assert :error = ArtifactURL.verify(nil)
  end

  test "a Phoenix.Token signed under any other salt does not verify here" do
    token = Phoenix.Token.sign(OrcaHubWeb.Endpoint, "user auth", @id)
    assert :error = ArtifactURL.verify(token)
  end

  test "raw_path/1 is relative, token-scoped and carries the version cache-buster" do
    path = ArtifactURL.raw_path(%{id: @id, version: 7})

    assert [_, token] = Regex.run(~r{\A/api/artifacts/view/([^/]+)/raw\?v=7\z}, path)
    assert {:ok, @id} = ArtifactURL.verify(token)
  end

  test "raw_url/1, asset_url/2 and urls/2 are absolute on the endpoint's public URL" do
    base = OrcaHubWeb.Endpoint.url()
    artifact = %{id: @id, version: 3}

    assert ArtifactURL.raw_url(artifact) == base <> ArtifactURL.raw_path(artifact)

    asset = ArtifactURL.asset_url(@id, "hero.png")
    assert [_, token] = Regex.run(~r{/api/artifacts/view/([^/]+)/assets/hero\.png\z}, asset)
    assert String.starts_with?(asset, base <> "/api/artifacts/view/")
    assert {:ok, @id} = ArtifactURL.verify(token)

    assert %{raw_url: raw, asset_urls: %{"a.png" => a, "b.mp4" => b}} =
             ArtifactURL.urls(artifact, ["a.png", "b.mp4"])

    assert raw == ArtifactURL.raw_url(artifact)
    assert a == ArtifactURL.asset_url(@id, "a.png")
    assert b == ArtifactURL.asset_url(@id, "b.mp4")
  end

  test "HubRPC minting matches local minting on the hub" do
    artifact = %{id: @id, version: 2, content: "never shipped"}

    assert OrcaHub.HubRPC.artifact_raw_url(artifact) == ArtifactURL.raw_url(artifact)
    assert OrcaHub.HubRPC.artifact_asset_url(@id, "x.png") == ArtifactURL.asset_url(@id, "x.png")

    assert OrcaHub.HubRPC.artifact_urls(artifact, ["x.png"]) ==
             ArtifactURL.urls(artifact, ["x.png"])
  end
end
