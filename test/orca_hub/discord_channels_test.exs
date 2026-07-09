defmodule OrcaHub.DiscordChannelsTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.{DiscordChannels, Projects, Sessions}

  defp fixture_project(name) do
    {:ok, project} =
      Projects.create_project(%{
        name: name,
        directory: "/tmp/#{name}",
        node: Atom.to_string(node())
      })

    project
  end

  defp fixture_session(project) do
    {:ok, session} =
      Sessions.create_session(%{directory: project.directory, project_id: project.id})

    session
  end

  describe "get_by_session_id/1" do
    test "returns nil when no mapping references the session" do
      project = fixture_project("discord-ctx-none")
      session = fixture_session(project)

      assert DiscordChannels.get_by_session_id(session.id) == nil
    end

    test "finds the mapping pointing at the session, with project preloaded" do
      project = fixture_project("discord-ctx-hit")
      session = fixture_session(project)

      {:ok, channel} =
        DiscordChannels.create_discord_channel(%{
          discord_channel_id: "1111",
          project_id: project.id
        })

      {:ok, channel} = DiscordChannels.set_session(channel, session.id)

      found = DiscordChannels.get_by_session_id(session.id)
      assert found.id == channel.id
      assert found.project.id == project.id
    end

    test "when multiple mappings somehow reference the same session, the most recently updated wins" do
      project = fixture_project("discord-ctx-multi")
      session = fixture_session(project)

      {:ok, older} =
        DiscordChannels.create_discord_channel(%{
          discord_channel_id: "2222",
          project_id: project.id
        })

      {:ok, newer} =
        DiscordChannels.create_discord_channel(%{
          discord_channel_id: "3333",
          project_id: project.id
        })

      {:ok, older} = DiscordChannels.set_session(older, session.id)
      {:ok, newer} = DiscordChannels.set_session(newer, session.id)

      # `timestamps()` here is second-precision (`utc_datetime`), so two
      # updates issued back-to-back in the same test can land in the same
      # second — force distinct `updated_at` values directly so the ordering
      # assertion doesn't depend on wall-clock timing.
      now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      older |> Ecto.Changeset.change(updated_at: NaiveDateTime.add(now, -60)) |> Repo.update!()
      newer |> Ecto.Changeset.change(updated_at: now) |> Repo.update!()

      found = DiscordChannels.get_by_session_id(session.id)
      assert found.id == newer.id
      refute found.id == older.id
    end

    test "a different session's mapping is not returned" do
      project = fixture_project("discord-ctx-other")
      session = fixture_session(project)
      other_session = fixture_session(project)

      {:ok, channel} =
        DiscordChannels.create_discord_channel(%{
          discord_channel_id: "4444",
          project_id: project.id
        })

      {:ok, _channel} = DiscordChannels.set_session(channel, session.id)

      assert DiscordChannels.get_by_session_id(other_session.id) == nil
    end
  end
end
