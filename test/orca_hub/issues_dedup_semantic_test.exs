defmodule OrcaHub.IssuesDedupSemanticTest do
  @moduledoc """
  Coverage for the SEMANTIC pass of `OrcaHub.Issues.find_similar_open_issue/3`
  and — the part that actually matters — its unconditional fallback to the
  lexical heuristic.

  Separate from `OrcaHub.IssuesTest` because these tests set the global
  `:embedding_url` app env, which an `async: true` file must not do. That is
  also why the fallback cases live here rather than there: dedup sits on the
  `create_issue` write path, so "the embedder is broken" must be a tested
  path, not an assumed one.
  """
  # async: false — global :embedding_url/:embedding_req_options app env.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.{Issues, Projects}
  alias OrcaHub.Issues.{Indexer, Issue}

  @stub OrcaHub.IssuesDedupStub
  @dims 1024

  setup do
    on_exit(fn ->
      Application.put_env(:orca_hub, :embedding_url, nil)
      Application.delete_env(:orca_hub, :embedding_req_options)
      Application.delete_env(:orca_hub, :issue_indexing)
    end)

    {:ok, project} =
      Projects.create_project(%{
        name: "dedup-semantic",
        directory: System.tmp_dir!(),
        node: Atom.to_string(node()),
        key_prefix: "DD" <> Integer.to_string(System.unique_integer([:positive]))
      })

    {:ok, project: project}
  end

  defp enable_embedder(mode \\ :sync) do
    Application.put_env(:orca_hub, :embedding_url, "http://embeddings.example.com")
    Application.put_env(:orca_hub, :embedding_req_options, plug: {Req.Test, @stub})
    Application.put_env(:orca_hub, :issue_indexing, mode)
  end

  # Returns a fixed unit vector, so every stored chunk and every query embed to
  # the SAME direction — cosine similarity 1.0, i.e. comfortably above the
  # 0.85 floor. That makes "did the semantic pass get consulted at all?"
  # observable without depending on the real model's geometry.
  defp identical_vector_stub do
    vec = [1.0 | List.duplicate(0.0, @dims - 1)]

    Req.Test.stub(@stub, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      inputs = Jason.decode!(raw)["input"]

      data =
        inputs
        |> Enum.with_index()
        |> Enum.map(fn {_t, i} -> %{"index" => i, "embedding" => vec} end)

      Req.Test.json(conn, %{"data" => data})
    end)
  end

  describe "the semantic pass" do
    test "catches a duplicate with NO lexical overlap at all", %{project: project} do
      enable_embedder()
      identical_vector_stub()

      # Indexed on creation by the write hook (sync mode).
      {:ok, existing} =
        Issues.create_issue(%{
          title: "Sessions pile up in the queue and never start",
          project_id: project.id
        })

      assert %Issue{} = Repo.get!(Issue, existing.id)

      # Zero shared words with the title above — the lexical heuristic cannot
      # match this, so a hit proves the semantic pass ran.
      candidate = "workers remain stuck awaiting dispatch forever"
      refute Issues.find_similar_open_issue(project.id, "task", candidate) == nil

      assert %Issue{id: id} = Issues.find_similar_open_issue(project.id, "task", candidate)
      assert id == existing.id
    end

    test "is scoped by kind and project like the lexical pass", %{project: project} do
      enable_embedder()
      identical_vector_stub()

      {:ok, _fr} =
        Issues.create_issue(%{
          title: "A feature request, not a task",
          project_id: project.id,
          kind: "feature_request"
        })

      # Same (identical-vector) semantics, but the only candidate is the wrong
      # kind — so dedup must find nothing rather than crossing kinds.
      assert Issues.find_similar_open_issue(project.id, "task", "anything at all") == nil

      {:ok, other_project} =
        Projects.create_project(%{
          name: "dedup-other-#{System.unique_integer([:positive])}",
          directory: System.tmp_dir!(),
          node: Atom.to_string(node()),
          key_prefix: "DO" <> Integer.to_string(System.unique_integer([:positive]))
        })

      assert Issues.find_similar_open_issue(other_project.id, "feature_request", "anything") ==
               nil
    end
  end

  describe "fallback — dedup must never be able to fail a write" do
    setup %{project: project} do
      # An issue that only the LEXICAL heuristic can match, created while the
      # embedder is off so nothing is indexed.
      {:ok, existing} = Issues.create_issue(%{title: "Fix the login bug", project_id: project.id})
      {:ok, existing: existing}
    end

    test "an endpoint returning 500 falls back to lexical", %{
      project: project,
      existing: existing
    } do
      enable_embedder()
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 500, "down") end)

      assert %Issue{id: id} =
               Issues.find_similar_open_issue(project.id, "task", "fix the login bug urgently")

      assert id == existing.id
    end

    test "an unreachable endpoint falls back to lexical", %{project: project, existing: existing} do
      enable_embedder()
      Req.Test.stub(@stub, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)

      assert %Issue{id: id} =
               Issues.find_similar_open_issue(project.id, "task", "fix the login bug urgently")

      assert id == existing.id
    end

    test "a garbage response falls back to lexical", %{project: project, existing: existing} do
      enable_embedder()
      Req.Test.stub(@stub, fn conn -> Req.Test.json(conn, %{"not" => "an embedding"}) end)

      assert %Issue{id: id} =
               Issues.find_similar_open_issue(project.id, "task", "fix the login bug urgently")

      assert id == existing.id
    end

    test "an indexed-but-not-similar corpus still allows a genuinely new issue through" do
      enable_embedder()
      identical_vector_stub()

      # Every vector is identical here, so this asserts the negative case the
      # *scoping* gives us rather than a distance threshold: no candidate of
      # this kind exists in a fresh project.
      {:ok, empty_project} =
        Projects.create_project(%{
          name: "dedup-empty-#{System.unique_integer([:positive])}",
          directory: System.tmp_dir!(),
          node: Atom.to_string(node()),
          key_prefix: "DE" <> Integer.to_string(System.unique_integer([:positive]))
        })

      assert Issues.find_similar_open_issue(empty_project.id, "task", "a brand new problem") ==
               nil
    end

    test "the write hook and dedup are independent: indexing off, dedup still works", %{
      project: project,
      existing: existing
    } do
      # Kill switch on indexing, embedder configured. Dedup's semantic pass may
      # find nothing (the corpus was never indexed), and lexical must carry it.
      Application.put_env(:orca_hub, :embedding_url, "http://embeddings.example.com")
      Application.put_env(:orca_hub, :embedding_req_options, plug: {Req.Test, @stub})
      Application.put_env(:orca_hub, :issue_indexing, :off)
      identical_vector_stub()

      assert Indexer.mode() == :off

      assert %Issue{id: id} =
               Issues.find_similar_open_issue(project.id, "task", "fix the login bug urgently")

      assert id == existing.id
    end
  end
end
