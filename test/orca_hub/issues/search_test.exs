defmodule OrcaHub.Issues.SearchTest do
  @moduledoc """
  Coverage for `OrcaHub.Issues.Search` — the read half of pgvector-backed
  issue indexing.

  The embedding endpoint is stubbed with `Req.Test`; nothing here touches
  the real one. Vectors are hand-built one-hot/mixture vectors so cosine
  ordering is exactly predictable rather than approximately so — the point
  of these tests is the QUERY and FUSION logic, not the model's judgment
  (that's verified against the real corpus; see the module's commit
  message).

  The degradation tests are the load-bearing ones: `EMBEDDING_URL` is unset
  for the whole suite, so "vector leg unavailable" is the DEFAULT state
  here, and `hybrid_search/2` returning lexical results anyway is what keeps
  the tool usable during a gb10 outage.
  """
  # async: false — these set the global :embedding_url/:embedding_req_options
  # app env, exactly like OrcaHub.EmbeddingsTest.
  use OrcaHub.DataCase, async: false

  alias OrcaHub.Issues
  alias OrcaHub.Issues.{IssueChunk, Search}
  alias OrcaHub.{Projects, Repo}

  @stub OrcaHub.Issues.SearchEmbeddingsStub
  @dims 1024

  # A one-hot unit vector: distinct axes are exactly orthogonal (cosine
  # similarity 0.0), an axis with itself is exactly 1.0.
  defp axis(i, dims \\ @dims) do
    Enum.map(0..(dims - 1), fn n -> if n == i, do: 1.0, else: 0.0 end)
  end

  # A unit vector `weight` of the way from axis `a` to axis `b`, so cosine
  # similarity against `axis(a)` is a known value between 0 and 1.
  defp blend(a, b, weight) do
    norm = :math.sqrt((1 - weight) * (1 - weight) + weight * weight)

    Enum.map(0..(@dims - 1), fn
      ^a -> (1 - weight) / norm
      ^b -> weight / norm
      _ -> 0.0
    end)
  end

  defp stub_embedding(vector) do
    Req.Test.stub(@stub, fn conn ->
      Req.Test.json(conn, %{
        "model" => "qwen3-embedding-0.6b",
        "object" => "list",
        "data" => [%{"index" => 0, "embedding" => vector, "object" => "embedding"}]
      })
    end)
  end

  defp enable_embeddings do
    Application.put_env(:orca_hub, :embedding_url, "http://embeddings.example.com")
    Application.put_env(:orca_hub, :embedding_req_options, plug: {Req.Test, @stub})
  end

  defp chunk!(issue, field, content, opts \\ []) do
    %IssueChunk{}
    |> IssueChunk.changeset(%{
      issue_id: issue.id,
      field: field,
      chunk_index: Keyword.get(opts, :chunk_index, 0),
      content: content,
      embedding: Keyword.get(opts, :embedding),
      embedding_model: Keyword.get(opts, :embedding) && "qwen3-embedding-0.6b",
      embedded_at: Keyword.get(opts, :embedding) && DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp project!(name) do
    dir = Path.join(System.tmp_dir!(), "issue_search_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, project} =
      Projects.create_project(%{name: name, directory: dir, node: to_string(node())})

    project
  end

  defp titles(results), do: Enum.map(results, & &1.issue.title)

  setup do
    # config/test.exs disables the endpoint; each test that wants it opts in
    # via enable_embeddings/0. Always restore, so a test enabling it can't
    # leak into the next one.
    #
    # Indexing is forced OFF for the same reason: enabling the embedder also
    # arms `OrcaHub.Issues.Indexer`'s write hooks, which would reindex (and
    # therefore replace) the hand-built chunk vectors below the moment a test
    # creates an issue. These tests are about the QUERY, so the corpus is
    # written by hand; the indexer has its own coverage.
    previous_indexing = Application.get_env(:orca_hub, :issue_indexing)
    Application.put_env(:orca_hub, :issue_indexing, :off)

    on_exit(fn ->
      Application.put_env(:orca_hub, :embedding_url, nil)
      Application.delete_env(:orca_hub, :embedding_req_options)

      if previous_indexing do
        Application.put_env(:orca_hub, :issue_indexing, previous_indexing)
      else
        Application.delete_env(:orca_hub, :issue_indexing)
      end
    end)

    project = project!("issue-search-test")

    {:ok, warm_port} =
      Issues.create_issue(%{
        title: "Warm port teardown leaks a file descriptor",
        description: "Every idle_teardown closes the port but keeps the fd, exhausting ulimit.",
        project_id: project.id
      })

    {:ok, cron_node} =
      Issues.create_issue(%{
        title: "Scheduled trigger fires on the wrong node",
        description: "Quantum picked a random node and the firing was silently dropped.",
        project_id: project.id
      })

    {:ok, closed} =
      Issues.create_issue(%{
        title: "Archived sessions still hold a warm slot",
        description: "A closed report about warm pool accounting.",
        project_id: project.id,
        status: "closed"
      })

    {:ok, feature} =
      Issues.create_issue(%{
        title: "Wanted: a search tool for issues",
        description: "Filing a duplicate because there is no way to search existing issues.",
        project_id: project.id,
        kind: "feature_request"
      })

    %{
      project: project,
      warm_port: warm_port,
      cron_node: cron_node,
      closed: closed,
      feature: feature
    }
  end

  describe "lexical_search/2" do
    test "finds an issue by a word in its title", %{warm_port: warm_port} do
      assert {:ok, [result]} = Search.lexical_search("file descriptor")
      assert result.issue.id == warm_port.id
      assert result.source == :lexical
      assert result.lexical_score > 0
      assert result.score == result.lexical_score
      assert is_nil(result.semantic_score)
    end

    test "finds an issue by a word only in its description", %{cron_node: cron_node} do
      assert {:ok, results} = Search.lexical_search("quantum")
      assert titles(results) == [cron_node.title]
      assert hd(results).field == "description"
    end

    test "reports which field matched and a snippet of it", %{warm_port: warm_port} do
      assert {:ok, [result]} = Search.lexical_search("ulimit")
      assert result.issue.id == warm_port.id
      assert result.field == "description"
      assert result.snippet =~ "ulimit"
    end

    test "stems, so a different inflection of the same word still matches" do
      assert {:ok, results} = Search.lexical_search("exhausted")
      assert "Warm port teardown leaks a file descriptor" in titles(results)
    end

    test "defaults to open issues only, and \"all\" includes closed ones", %{closed: closed} do
      assert {:ok, results} = Search.lexical_search("warm")
      refute closed.id in Enum.map(results, & &1.issue.id)

      assert {:ok, all} = Search.lexical_search("warm", status: "all")
      assert closed.id in Enum.map(all, & &1.issue.id)
    end

    test "accepts a list of statuses", %{closed: closed, warm_port: warm_port} do
      assert {:ok, results} = Search.lexical_search("warm", status: ["open", "closed"])
      ids = Enum.map(results, & &1.issue.id)
      assert closed.id in ids
      assert warm_port.id in ids
    end

    test "filters by kind", %{feature: feature} do
      assert {:ok, results} = Search.lexical_search("search issues", kind: "feature_request")
      assert titles(results) == [feature.title]

      assert {:ok, []} = Search.lexical_search("search issues", kind: "task")
    end

    test "filters by project" do
      other = project!("issue-search-other")

      {:ok, elsewhere} =
        Issues.create_issue(%{
          title: "Warm port teardown in another project",
          project_id: other.id
        })

      assert {:ok, results} = Search.lexical_search("teardown", project_id: other.id)
      assert titles(results) == [elsewhere.title]
    end

    test "filters by creating session", %{project: project} do
      session = session_fixture(project)

      {:ok, mine} =
        Issues.create_issue(%{
          title: "Warm port teardown filed by me",
          project_id: project.id,
          created_by_session_id: session.id
        })

      assert {:ok, results} =
               Search.lexical_search("teardown", created_by_session_id: session.id)

      assert titles(results) == [mine.title]
    end

    test "honours limit" do
      assert {:ok, results} = Search.lexical_search("warm OR port OR node", limit: 1)
      assert length(results) <= 1
    end

    test "supports websearch operators: quoted phrases and negation" do
      assert {:ok, phrase} = Search.lexical_search("\"file descriptor\"")
      assert length(phrase) == 1

      assert {:ok, negated} = Search.lexical_search("warm -teardown")
      refute "Warm port teardown leaks a file descriptor" in titles(negated)
    end

    test "a blank query is an empty result, not an error" do
      assert {:ok, []} = Search.lexical_search("")
      assert {:ok, []} = Search.lexical_search("   ")
    end

    test "a query matching nothing returns an empty list" do
      assert {:ok, []} = Search.lexical_search("zzzznotawordanywhere")
    end

    test "a non-string query is rejected rather than crashing" do
      assert {:error, {:invalid_query, nil}} = Search.lexical_search(nil)
    end
  end

  describe "lexical_search/2 relaxation" do
    # websearch_to_tsquery ANDs bare terms, so a sentence-length query
    # matches nothing at all — measured on the real corpus: zero lexical
    # hits for every one of eight natural-language paraphrase queries.
    @sentence "a timer I set to remind myself later silently did nothing while the port leaks"

    test "strict matching (the default) requires EVERY term" do
      assert {:ok, []} = Search.lexical_search(@sentence)
    end

    test "relax: true falls back to any-term matching when strict finds nothing", %{
      warm_port: warm_port
    } do
      assert {:ok, results} = Search.lexical_search(@sentence, relax: true)
      assert warm_port.id in Enum.map(results, & &1.issue.id)
    end

    test "relax: true does NOT widen a query that strict already answered", %{
      warm_port: warm_port
    } do
      assert {:ok, strict} = Search.lexical_search("file descriptor")
      assert {:ok, relaxed} = Search.lexical_search("file descriptor", relax: true)

      assert Enum.map(strict, & &1.issue.id) == Enum.map(relaxed, & &1.issue.id)
      assert titles(relaxed) == [warm_port.title]
    end

    test "a -exclusion is never relaxed — ORing it would invert what was asked" do
      # "-teardown" excludes the only issue the other terms could reach, so
      # strict is empty; relaxing `a & !b` to `a | !b` would match nearly
      # everything instead.
      assert {:ok, []} = Search.lexical_search("descriptor ulimit -teardown", relax: true)
    end

    test "a quoted phrase is never relaxed" do
      assert {:ok, []} =
               Search.lexical_search("\"file descriptor\" \"quantum scheduler\"", relax: true)
    end
  end

  describe "hybrid_search/2 relaxation" do
    test "relaxes only when the vector leg is GONE, so noise can't dilute a good fusion", %{
      warm_port: warm_port
    } do
      enable_embeddings()
      chunk!(warm_port, "title", "title: #{warm_port.title}", embedding: axis(0))
      stub_embedding(axis(1))

      # Vector leg healthy: the sentence contributes no lexical hits and is
      # NOT widened, so nothing noisy enters the fusion.
      assert {:ok, _results, meta} = Search.hybrid_search_meta(@sentence)
      assert meta.lexical == :ok
      refute meta.degraded
    end

    test "with the vector leg down, a sentence query returns leads instead of nothing", %{
      warm_port: warm_port
    } do
      refute OrcaHub.Embeddings.enabled?()

      # Without relaxation this is the worst case: embeddings down AND a
      # natural-language query, i.e. no results whatsoever.
      assert {:ok, results, meta} = Search.hybrid_search_meta(@sentence)

      assert meta.semantic == {:error, :disabled}
      assert meta.lexical == :relaxed
      assert meta.degraded
      assert warm_port.id in Enum.map(results, & &1.issue.id)
    end

    test "meta reports both legs healthy when they are", %{warm_port: warm_port} do
      enable_embeddings()
      chunk!(warm_port, "title", "title: #{warm_port.title}", embedding: axis(0))
      stub_embedding(axis(0))

      assert {:ok, _results, meta} = Search.hybrid_search_meta("file descriptor")
      assert meta == %{semantic: :ok, lexical: :ok, degraded: false}
    end
  end

  describe "semantic_search/2 when embeddings are unavailable" do
    test "returns {:error, :disabled} — the suite's default state" do
      refute OrcaHub.Embeddings.enabled?()
      assert {:error, :disabled} = Search.semantic_search("anything")
    end

    test "a blank query short-circuits before the endpoint is consulted" do
      assert {:ok, []} = Search.semantic_search("")
    end
  end

  describe "semantic_search/2" do
    setup %{warm_port: warm_port, cron_node: cron_node, closed: closed} do
      enable_embeddings()

      chunk!(warm_port, "title", "title: #{warm_port.title}", embedding: axis(0))
      chunk!(cron_node, "title", "title: #{cron_node.title}", embedding: axis(1))
      chunk!(closed, "title", "title: #{closed.title}", embedding: axis(0))

      :ok
    end

    test "orders by cosine similarity to the query vector", %{
      warm_port: warm_port,
      cron_node: cron_node
    } do
      stub_embedding(axis(0))

      assert {:ok, results} = Search.semantic_search("fds are leaking somewhere")
      assert [first | rest] = results
      assert first.issue.id == warm_port.id
      assert_in_delta first.score, 1.0, 0.0001
      assert first.source == :semantic
      assert first.semantic_score == first.score
      assert is_nil(first.lexical_score)

      assert cron_node.id in Enum.map(rest, & &1.issue.id)
      assert Enum.all?(rest, &(&1.score < first.score))
    end

    test "strips the chunker's field label off the snippet", %{warm_port: warm_port} do
      stub_embedding(axis(0))

      assert {:ok, [first | _]} = Search.semantic_search("fds leaking")
      assert first.field == "title"
      assert first.snippet == warm_port.title
      refute first.snippet =~ "title: "
    end

    test "returns the BEST chunk per issue, not one row per chunk", %{warm_port: warm_port} do
      chunk!(warm_port, "notes", "notes: unrelated rambling", chunk_index: 0, embedding: axis(7))

      chunk!(warm_port, "description", "description: the good one", embedding: blend(0, 9, 0.1))

      stub_embedding(axis(0))

      assert {:ok, results} = Search.semantic_search("fds leaking")
      matches = Enum.filter(results, &(&1.issue.id == warm_port.id))

      assert length(matches) == 1
      # The title chunk sits exactly on axis(0), so it beats both the
      # near-axis description chunk and the orthogonal notes chunk.
      assert hd(matches).field == "title"
    end

    test "ignores chunks that have no embedding yet", %{project: project} do
      {:ok, unembedded} =
        Issues.create_issue(%{title: "Not yet indexed at all", project_id: project.id})

      chunk!(unembedded, "title", "title: #{unembedded.title}")

      stub_embedding(axis(0))

      assert {:ok, results} = Search.semantic_search("anything at all", limit: 50)
      refute unembedded.id in Enum.map(results, & &1.issue.id)
    end

    test "applies the same filters as the lexical leg", %{closed: closed, project: project} do
      stub_embedding(axis(0))

      assert {:ok, open_only} = Search.semantic_search("fds leaking")
      refute closed.id in Enum.map(open_only, & &1.issue.id)

      assert {:ok, all} = Search.semantic_search("fds leaking", status: "all")
      assert closed.id in Enum.map(all, & &1.issue.id)

      assert {:ok, scoped} = Search.semantic_search("fds leaking", project_id: project.id)
      assert scoped != []

      assert {:ok, []} = Search.semantic_search("fds leaking", project_id: Ecto.UUID.generate())
    end

    test "honours limit" do
      stub_embedding(axis(0))
      assert {:ok, [_only_one]} = Search.semantic_search("fds leaking", limit: 1)
    end

    test "surfaces an embedding failure rather than silently returning nothing" do
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 500, "boom") end)

      assert {:error, {:http_error, 500, _}} = Search.semantic_search("fds leaking")
    end
  end

  describe "hybrid_search/2 degradation" do
    test "with embeddings disabled, returns lexical results instead of an error", %{
      warm_port: warm_port
    } do
      refute OrcaHub.Embeddings.enabled?()

      assert {:ok, [result]} = Search.hybrid_search("file descriptor")
      assert result.issue.id == warm_port.id
      assert result.source == :lexical
      assert result.lexical_score > 0
    end

    test "with embeddings erroring, still returns lexical results", %{warm_port: warm_port} do
      enable_embeddings()
      Req.Test.stub(@stub, fn conn -> Plug.Conn.send_resp(conn, 503, "gb10 is down") end)

      assert {:ok, results} = Search.hybrid_search("file descriptor")
      assert titles(results) == [warm_port.title]
      assert hd(results).source == :lexical
    end

    test "a failing lexical leg does not take out the vector leg", %{warm_port: warm_port} do
      enable_embeddings()
      chunk!(warm_port, "title", "title: #{warm_port.title}", embedding: axis(0))
      stub_embedding(axis(0))

      # Over a megabyte: websearch_to_tsquery hard-errors on this, which is
      # the cheapest genuine full-text failure to provoke — and an agent
      # pasting a huge blob as its query is not hypothetical.
      huge = String.duplicate("descriptor ", 120_000)

      assert {:error, _} = Search.lexical_search(huge)
      assert {:ok, results} = Search.hybrid_search(huge)
      assert titles(results) == [warm_port.title]
      assert hd(results).source == :semantic
    end

    test "when BOTH legs fail, the error surfaces" do
      huge = String.duplicate("descriptor ", 120_000)

      refute OrcaHub.Embeddings.enabled?()
      assert {:error, _reason} = Search.hybrid_search(huge)
    end

    test "a blank query is an empty result, not an error" do
      assert {:ok, []} = Search.hybrid_search("  ")
    end
  end

  describe "hybrid_search/2 fusion" do
    test "an issue found by both legs outranks the issue that WON a leg outright", %{
      project: project,
      cron_node: cron_node
    } do
      enable_embeddings()

      # cron_node mentions "quantum" in its description (weight B) and wins
      # the lexical leg outright, but has no vector at all. `both` mentions
      # it only in notes (weight D) so it ranks SECOND lexically — and first
      # semantically. RRF: both = 1/61 + 1/62 = 0.0325, cron_node = 1/61 =
      # 0.0164. Fusion must therefore lift `both` over the leg winner, which
      # is the entire reason for fusing rather than concatenating.
      {:ok, both} =
        Issues.create_issue(%{
          title: "Port teardown accounting",
          description: "Ports are not released on teardown.",
          notes: "Possibly related to the quantum scheduler, unclear.",
          project_id: project.id
        })

      chunk!(both, "title", "title: #{both.title}", embedding: axis(0))
      stub_embedding(axis(0))

      assert {:ok, lexical} = Search.lexical_search("quantum")
      assert titles(lexical) == [cron_node.title, both.title]

      assert {:ok, results} = Search.hybrid_search("quantum")
      assert [first, second] = results

      assert first.issue.id == both.id
      assert first.source == :both
      assert first.semantic_score
      assert first.lexical_score
      assert first.score > second.score

      assert second.issue.id == cron_node.id
      assert second.source == :lexical
      assert is_nil(second.semantic_score)
    end

    test "the fused score is an RRF score, not either leg's native score", %{
      warm_port: warm_port
    } do
      enable_embeddings()
      chunk!(warm_port, "title", "title: #{warm_port.title}", embedding: axis(0))
      stub_embedding(axis(0))

      assert {:ok, [first]} = Search.hybrid_search("file descriptor")
      # Rank 1 in both legs: 1/(60+1) * 2.
      assert_in_delta first.score, 2 / (Search.rrf_k() + 1), 0.0001
      # ...while the cosine similarity it also carries is ~1.0.
      assert_in_delta first.semantic_score, 1.0, 0.0001
    end

    test "prefers the semantic leg's snippet, which is the chunk that matched", %{
      warm_port: warm_port
    } do
      enable_embeddings()

      chunk!(warm_port, "notes", "notes: the descriptor table never shrinks", embedding: axis(0))

      stub_embedding(axis(0))

      assert {:ok, [first]} = Search.hybrid_search("file descriptor")
      assert first.source == :both
      assert first.field == "notes"
      assert first.snippet == "the descriptor table never shrinks"
    end

    test "honours limit after fusion" do
      enable_embeddings()
      stub_embedding(axis(3))

      assert {:ok, results} = Search.hybrid_search("warm OR quantum OR search", limit: 2)
      assert length(results) <= 2
    end
  end

  describe "similar_issues/2" do
    setup %{warm_port: warm_port, cron_node: cron_node} do
      enable_embeddings()
      chunk!(warm_port, "title", "title: #{warm_port.title}", embedding: axis(0))
      chunk!(cron_node, "title", "title: #{cron_node.title}", embedding: axis(1))
      :ok
    end

    test "returns a near-identical issue", %{warm_port: warm_port} do
      stub_embedding(axis(0))

      assert {:ok, [result]} = Search.similar_issues("fds leak when a port is torn down")
      assert result.issue.id == warm_port.id
      assert result.score >= Search.similar_threshold()
    end

    test "drops everything below the threshold rather than returning a least-bad match" do
      # 0.5 of the way to another axis is a cosine similarity of ~0.707 —
      # above the default floor, below an explicitly raised one.
      stub_embedding(blend(0, 400, 0.5))

      assert {:ok, [_above_default]} = Search.similar_issues("vaguely about ports")
      assert {:ok, []} = Search.similar_issues("vaguely about ports", threshold: 0.9)
    end

    test "includes in_progress issues, which a plain search's default would miss", %{
      project: project
    } do
      {:ok, in_progress} =
        Issues.create_issue(%{
          title: "Being worked on right now",
          project_id: project.id,
          status: "in_progress"
        })

      chunk!(in_progress, "title", "title: #{in_progress.title}", embedding: axis(42))
      stub_embedding(axis(42))

      assert {:ok, [result]} = Search.similar_issues("already under way")
      assert result.issue.id == in_progress.id

      # ...whereas the plain default ("open" exactly) does not.
      assert {:ok, plain} = Search.semantic_search("already under way")
      refute in_progress.id in Enum.map(plain, & &1.issue.id)
    end

    test "excludes closed issues", %{closed: closed} do
      chunk!(closed, "title", "title: #{closed.title}", embedding: axis(77))
      stub_embedding(axis(77))

      assert {:ok, results} = Search.similar_issues("warm slots held by archived sessions")
      refute closed.id in Enum.map(results, & &1.issue.id)
    end

    test "scopes by kind and project", %{feature: feature, project: project} do
      chunk!(feature, "title", "title: #{feature.title}", embedding: axis(9))
      stub_embedding(axis(9))

      assert {:ok, [result]} =
               Search.similar_issues("a way to look issues up",
                 kind: "feature_request",
                 project_id: project.id
               )

      assert result.issue.id == feature.id

      assert {:ok, []} =
               Search.similar_issues("a way to look issues up",
                 kind: "task",
                 project_id: project.id
               )
    end

    test "is {:error, :disabled} — NOT an empty list — when embeddings are off" do
      Application.put_env(:orca_hub, :embedding_url, nil)

      # This distinction is the whole contract for a dedup caller: an empty
      # list means "definitely nothing similar", an error means "unknown,
      # fall back to your own heuristic".
      assert {:error, :disabled} = Search.similar_issues("fds leak on teardown")
    end
  end

  defp session_fixture(project) do
    {:ok, session} =
      OrcaHub.Sessions.create_session(%{
        directory: project.directory,
        project_id: project.id
      })

    session
  end
end
