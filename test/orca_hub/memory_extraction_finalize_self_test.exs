defmodule OrcaHub.MemoryExtractionFinalizeSelfTest do
  @moduledoc """
  DB-backed coverage for `OrcaHub.MemoryExtraction.finalize_self/2` — the
  self-archiving hook `OrcaHub.SessionRunner` calls directly at every
  idle/error turn-end transition for a `kind == "memory_extraction"`
  session, replacing the old in-memory completion-watcher `Task` that died
  on every hub restart. Single-node test env means `Cluster.rpc/5`
  resolves the child's own `runner_node` locally (`n == node()`), so the
  transcript-file delete/retry-respawn paths exercise real disk I/O
  without any node stubbing.
  """

  use OrcaHub.DataCase, async: false

  alias OrcaHub.{MemoryExtraction, Projects, Sessions}

  @fallback_backend "claude"
  @fallback_model "claude-haiku-4-5-20251001"
  @claude_stub Path.expand("../support/fixtures/claude_stub_noop.sh", __DIR__)

  setup do
    dir =
      Path.join(System.tmp_dir!(), "orca-mem-ext-finalize-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} = Projects.create_project(%{name: "Test", directory: dir})
    %{project: project, dir: dir}
  end

  defp create_source(project) do
    {:ok, source} =
      Sessions.create_session(%{directory: project.directory, project_id: project.id})

    source
  end

  defp create_child(project, source, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          directory: project.directory,
          project_id: project.id,
          parent_session_id: source.id,
          kind: "memory_extraction",
          runner_node: Atom.to_string(node()),
          backend: "pi",
          model: "some/other-model",
          notify_parent: false,
          memory_extract: false,
          status: "ready"
        },
        overrides
      )

    {:ok, child} = Sessions.create_session(attrs)
    child
  end

  defp write_transcript(project, source) do
    path = MemoryExtraction.transcript_file_path(%{directory: project.directory, id: source.id})
    MemoryExtraction.write_transcript_file!(path, "transcript contents")
    path
  end

  describe "finalize_self/2 — :idle" do
    test "archives the child, posts a visibility event to the source, and deletes the transcript file",
         %{project: project} do
      source = create_source(project)
      child = create_child(project, source)
      path = write_transcript(project, source)

      assert MemoryExtraction.finalize_self(child, :idle) == :ok

      reloaded = Sessions.get_session(child.id)
      refute is_nil(reloaded.archived_at)

      refute File.exists?(path)

      [event] = Sessions.list_messages(source.id)
      assert event.data["type"] == "system"
      assert event.data["subtype"] == "memory_extraction"
    end
  end

  describe "finalize_self/2 — :error, non-retryable" do
    test "backend/model already the fallback pair: posts a failure event, deletes the file, archives",
         %{project: project} do
      source = create_source(project)
      child = create_child(project, source, %{backend: @fallback_backend, model: @fallback_model})
      path = write_transcript(project, source)

      assert MemoryExtraction.finalize_self(child, :error) == :ok

      reloaded = Sessions.get_session(child.id)
      refute is_nil(reloaded.archived_at)
      refute File.exists?(path)

      [event] = Sessions.list_messages(source.id)
      assert event.data["subtype"] == "memory_extraction"
      assert event.data["message"] =~ "failed"
    end
  end

  describe "finalize_self/2 — :error, retryable" do
    setup do
      # The retry path spawns a real replacement session (Cluster.start_session +
      # send_message) — stub the CLI so it just reads/discards stdin instead of
      # exec'ing the real `claude` binary. See claude_stub_noop.sh's own doc.
      Application.put_env(:orca_hub, :claude_executable, @claude_stub)
      on_exit(fn -> Application.delete_env(:orca_hub, :claude_executable) end)
      :ok
    end

    test "different backend/model with no tool calls: archives the failed child and respawns " <>
           "with the fallback pair, keeping the transcript file for the retry",
         %{project: project} do
      source = create_source(project)
      child = create_child(project, source)
      path = write_transcript(project, source)

      assert MemoryExtraction.finalize_self(child, :error) == :ok

      reloaded = Sessions.get_session(child.id)
      refute is_nil(reloaded.archived_at)

      # Reused, not deleted — the retry needs the same file.
      assert File.exists?(path)

      retry =
        Sessions.list_sessions(:all, include_background: true)
        |> Enum.find(&(&1.parent_session_id == source.id and &1.id != child.id))

      assert retry
      assert retry.kind == "memory_extraction"
      assert retry.backend == @fallback_backend
      assert retry.model == @fallback_model
      assert is_nil(retry.archived_at)

      on_exit(fn ->
        if OrcaHub.SessionSupervisor.session_alive?(retry.id) do
          OrcaHub.SessionSupervisor.stop_session(retry.id)
        end
      end)

      # No visibility message yet — the retry hasn't finished.
      assert Sessions.list_messages(source.id) == []
    end
  end

  describe "finalize_self/2 — idempotency" do
    test "a second call on an already-archived child is a no-op", %{project: project} do
      source = create_source(project)
      child = create_child(project, source, %{backend: @fallback_backend, model: @fallback_model})
      write_transcript(project, source)

      assert MemoryExtraction.finalize_self(child, :error) == :ok
      archived_once = Sessions.get_session(child.id)

      assert MemoryExtraction.finalize_self(archived_once, :error) == :ok
      assert MemoryExtraction.finalize_self(archived_once, :idle) == :ok

      # Only one failure event, not three.
      assert length(Sessions.list_messages(source.id)) == 1
    end
  end
end
