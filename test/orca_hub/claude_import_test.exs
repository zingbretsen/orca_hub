defmodule OrcaHub.ClaudeImportTest do
  @moduledoc """
  Regression coverage for `import_session/5`'s bulk message insert.

  `Message.inserted_at`/`updated_at` are `:naive_datetime_usec`, but
  `Repo.insert_all` bypasses changesets/autogeneration, so any timestamp
  handed to it must already carry microsecond precision (see
  `ClaudeImport`'s `parse_naive_timestamp/1` / `pad_usec/1`). Prior to that
  fix, this whole import silently failed (caught by `import_all/1`'s
  `rescue`) with `ArgumentError: :naive_datetime_usec expects microsecond
  precision`.

  Not async: uses the `:orca_hub, :claude_home_override` Application env
  seam (mirrors `OrcaHub.NodeConfig`'s `:node_config_home` pattern) to
  point `ClaudeImport` at a tmp directory instead of the real `~/.claude`.
  """
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{ClaudeImport, Repo}
  alias OrcaHub.Sessions.{Message, Session}

  setup do
    original = Application.get_env(:orca_hub, :claude_home_override)

    claude_home =
      Path.join(System.tmp_dir!(), "claude_import_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(claude_home)
    Application.put_env(:orca_hub, :claude_home_override, claude_home)

    on_exit(fn ->
      if original,
        do: Application.put_env(:orca_hub, :claude_home_override, original),
        else: Application.delete_env(:orca_hub, :claude_home_override)

      File.rm_rf(claude_home)
    end)

    {:ok, claude_home: claude_home}
  end

  # Claude project dirs are stored flat under projects/ with "-" standing in
  # for "/" in the real working directory; a single-segment, hyphen-free
  # name keeps decode_project_dir's fallback path deterministic without
  # needing a real directory on disk.
  defp write_transcript!(claude_home, project_segment, session_id, lines) do
    project_dir = Path.join([claude_home, "projects", "-" <> project_segment])
    File.mkdir_p!(project_dir)

    content = lines |> Enum.map(&Jason.encode!/1) |> Enum.join("\n")
    File.write!(Path.join(project_dir, "#{session_id}.jsonl"), content)
  end

  test "imports a transcript and bulk-inserts messages with usec-precision timestamps", %{
    claude_home: claude_home
  } do
    session_id = Ecto.UUID.generate()
    project_segment = "claudeimporttestproj#{System.unique_integer([:positive])}"

    write_transcript!(claude_home, project_segment, session_id, [
      %{
        "type" => "user",
        "cwd" => "/#{project_segment}",
        "timestamp" => "2026-01-01T12:00:00.123Z",
        "message" => %{"role" => "user", "content" => "hello there"}
      },
      %{
        "type" => "assistant",
        "cwd" => "/#{project_segment}",
        "timestamp" => "2026-01-01T12:00:01.456Z",
        "message" => %{
          "role" => "assistant",
          "model" => "claude-test",
          "content" => [%{"type" => "text", "text" => "hi!"}]
        }
      }
    ])

    summary = ClaudeImport.import_all([])

    assert summary.errors == []
    assert summary.sessions_imported == 1

    session = Repo.get_by!(Session, claude_session_id: session_id)

    messages =
      Message
      |> Ecto.Query.where(session_id: ^session.id)
      |> Ecto.Query.order_by(:inserted_at)
      |> Repo.all()

    assert length(messages) == 2
    assert Enum.map(messages, & &1.data["type"]) == ["user", "assistant"]

    for message <- messages do
      assert {_, 6} = message.inserted_at.microsecond
      assert {_, 6} = message.updated_at.microsecond
    end

    [first, second] = messages
    assert first.inserted_at == ~N[2026-01-01 12:00:00.123000]
    assert second.inserted_at == ~N[2026-01-01 12:00:01.456000]
  end

  test "falls back to distinct usec-precision timestamps for messages without one", %{
    claude_home: claude_home
  } do
    session_id = Ecto.UUID.generate()
    project_segment = "claudeimportfallback#{System.unique_integer([:positive])}"

    write_transcript!(claude_home, project_segment, session_id, [
      %{
        "type" => "user",
        "cwd" => "/#{project_segment}",
        "message" => %{"role" => "user", "content" => "no timestamp here"}
      },
      %{
        "type" => "assistant",
        "cwd" => "/#{project_segment}",
        "message" => %{
          "role" => "assistant",
          "content" => [%{"type" => "text", "text" => "also no timestamp"}]
        }
      }
    ])

    summary = ClaudeImport.import_all([])

    assert summary.errors == []
    assert summary.sessions_imported == 1

    session = Repo.get_by!(Session, claude_session_id: session_id)

    messages =
      Message
      |> Ecto.Query.where(session_id: ^session.id)
      |> Ecto.Query.order_by(:inserted_at)
      |> Repo.all()

    assert length(messages) == 2

    for message <- messages do
      assert {_, 6} = message.inserted_at.microsecond
    end

    assert NaiveDateTime.compare(hd(messages).inserted_at, List.last(messages).inserted_at) == :lt
  end
end
