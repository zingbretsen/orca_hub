defmodule Mix.Tasks.Orca.BackfillSessionInteractionsTest do
  use OrcaHub.DataCase

  alias OrcaHub.{Projects, Repo, Sessions}
  alias OrcaHub.Sessions.Message

  setup do
    {:ok, project} =
      Projects.create_project(%{name: "Test", directory: "/tmp/test-backfill-interactions"})

    {:ok, sender} =
      Sessions.create_session(%{directory: project.directory, project_id: project.id})

    {:ok, recipient} =
      Sessions.create_session(%{directory: project.directory, project_id: project.id})

    %{sender: sender, recipient: recipient}
  end

  defp insert_message!(session_id, data, inserted_at) do
    ts = inserted_at |> NaiveDateTime.truncate(:second)

    {1, _} =
      Repo.insert_all(Message, [
        %{
          id: Ecto.UUID.generate(),
          session_id: session_id,
          data: data,
          inserted_at: ts,
          updated_at: ts
        }
      ])

    :ok
  end

  defp block_message(text) do
    %{
      "type" => "user",
      "message" => %{"role" => "user", "content" => [%{"type" => "text", "text" => text}]}
    }
  end

  defp string_message(text) do
    %{"type" => "user", "message" => %{"role" => "user", "content" => text}}
  end

  test "inserts an edge for a matching prefixed message (list-of-blocks shape)", %{
    sender: sender,
    recipient: recipient
  } do
    stamp = ~N[2026-01-01 12:00:00]
    text = "[Message from session #{sender.id}]\n\nhello there"
    insert_message!(recipient.id, block_message(text), stamp)

    Mix.Tasks.Orca.BackfillSessionInteractions.run([])

    assert [interaction] = Sessions.list_session_interactions(recipient_session_id: recipient.id)
    assert interaction.sender_session_id == sender.id
    assert interaction.recipient_session_id == recipient.id
    assert interaction.kind == "message"
    assert interaction.inserted_at == stamp
  end

  test "inserts an edge for a matching prefixed message (plain-string content shape)", %{
    sender: sender,
    recipient: recipient
  } do
    stamp = ~N[2026-01-02 08:30:00]
    text = "[Message from session #{sender.id}]\n\nimported message"
    insert_message!(recipient.id, string_message(text), stamp)

    Mix.Tasks.Orca.BackfillSessionInteractions.run([])

    assert [interaction] = Sessions.list_session_interactions(recipient_session_id: recipient.id)
    assert interaction.sender_session_id == sender.id
    assert interaction.inserted_at == stamp
  end

  test "skips messages without the prefix", %{recipient: recipient} do
    insert_message!(recipient.id, block_message("just a normal prompt"), ~N[2026-01-01 00:00:00])

    Mix.Tasks.Orca.BackfillSessionInteractions.run([])

    assert Sessions.list_session_interactions(recipient_session_id: recipient.id) == []
  end

  test "skips non-user messages even if they contain the prefix text", %{
    sender: sender,
    recipient: recipient
  } do
    text = "[Message from session #{sender.id}]\n\nhello there"

    insert_message!(
      recipient.id,
      %{
        "type" => "assistant",
        "message" => %{"role" => "assistant", "content" => [%{"type" => "text", "text" => text}]}
      },
      ~N[2026-01-01 00:00:00]
    )

    Mix.Tasks.Orca.BackfillSessionInteractions.run([])

    assert Sessions.list_session_interactions(recipient_session_id: recipient.id) == []
  end

  test "skips a match whose sender uuid doesn't correspond to an existing session", %{
    recipient: recipient
  } do
    bogus_sender = Ecto.UUID.generate()
    text = "[Message from session #{bogus_sender}]\n\nhello there"
    insert_message!(recipient.id, block_message(text), ~N[2026-01-01 00:00:00])

    Mix.Tasks.Orca.BackfillSessionInteractions.run([])

    assert Sessions.list_session_interactions(recipient_session_id: recipient.id) == []
  end

  test "is idempotent across repeated runs", %{sender: sender, recipient: recipient} do
    stamp = ~N[2026-01-01 12:00:00]
    text = "[Message from session #{sender.id}]\n\nhello there"
    insert_message!(recipient.id, block_message(text), stamp)

    Mix.Tasks.Orca.BackfillSessionInteractions.run([])
    Mix.Tasks.Orca.BackfillSessionInteractions.run([])

    assert [_one] = Sessions.list_session_interactions(recipient_session_id: recipient.id)
  end
end
