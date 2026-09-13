defmodule OrcaHub.ToolPolicyTest do
  use OrcaHub.DataCase, async: true

  alias OrcaHub.{Sessions, ToolPolicy}

  defp policy(allow, deny), do: ToolPolicy.new(allow, deny)

  describe "allowed?/2 — exact names" do
    test "an allowlist restricts to exactly its entries" do
      p = policy(["report_progress", "open_file"], nil)

      assert ToolPolicy.allowed?(p, "report_progress")
      assert ToolPolicy.allowed?(p, "open_file")
      refute ToolPolicy.allowed?(p, "start_session")
      refute ToolPolicy.allowed?(p, "github__get_issue")
    end

    test "a denylist refuses exactly its entries" do
      p = policy(nil, ["start_session"])

      refute ToolPolicy.allowed?(p, "start_session")
      assert ToolPolicy.allowed?(p, "report_progress")
    end

    test "matching is case-sensitive" do
      p = policy(nil, ["Start_Session"])
      assert ToolPolicy.allowed?(p, "start_session")
    end

    test "an entry is an exact match, not a prefix/substring match" do
      p = policy(nil, ["start_session"])
      assert ToolPolicy.allowed?(p, "start_session_group")
      assert ToolPolicy.allowed?(p, "restart_session")
    end
  end

  describe "allowed?/2 — `*` globs" do
    test "a trailing glob matches any suffix, including the __ separator" do
      p = policy(nil, ["github__*"])

      refute ToolPolicy.allowed?(p, "github__get_issue")
      refute ToolPolicy.allowed?(p, "github__list__issues")
      assert ToolPolicy.allowed?(p, "gitlab__get_issue")
      # `github__*` requires something after the prefix
      assert ToolPolicy.allowed?(p, "github")
    end

    test "a leading glob matches any prefix" do
      p = policy(["*_issue"], nil)

      assert ToolPolicy.allowed?(p, "github__get_issue")
      assert ToolPolicy.allowed?(p, "close_issue")
      refute ToolPolicy.allowed?(p, "list_issues")
    end

    test "an interior glob matches any run of characters" do
      p = policy(nil, ["*__browser_*"])

      refute ToolPolicy.allowed?(p, "playwright__browser_evaluate")
      assert ToolPolicy.allowed?(p, "playwright__snapshot")
    end

    test "`?` and character classes are NOT wildcards — they are literal" do
      p = policy(nil, ["open_fil?", "open_[a-z]ile"])

      assert ToolPolicy.allowed?(p, "open_file")
      refute ToolPolicy.allowed?(p, "open_fil?")
      refute ToolPolicy.allowed?(p, "open_[a-z]ile")
    end

    test "regex metacharacters in an entry are escaped, not interpreted" do
      p = policy(nil, ["a.c"])

      assert ToolPolicy.allowed?(p, "abc")
      refute ToolPolicy.allowed?(p, "a.c")
    end
  end

  describe "allowed?/2 — deny wins" do
    test "a tool on both lists is refused" do
      p = policy(["report_progress", "start_session"], ["start_session"])

      assert ToolPolicy.allowed?(p, "report_progress")
      refute ToolPolicy.allowed?(p, "start_session")
    end

    test "a deny glob beats an exact allow" do
      p = policy(["github__get_issue"], ["github__*"])
      refute ToolPolicy.allowed?(p, "github__get_issue")
    end
  end

  describe "allowed?/2 — empty/nil semantics" do
    test "nil allowlist means unrestricted, NOT deny-everything" do
      p = policy(nil, nil)

      assert ToolPolicy.allowed?(p, "anything_at_all")
      refute ToolPolicy.restricted?(p)
    end

    test "[] allowlist means unrestricted too (form casting turns an untouched field into [])" do
      p = policy([], [])

      assert ToolPolicy.allowed?(p, "start_session")
      refute ToolPolicy.restricted?(p)
    end

    test "blank/non-string entries are dropped rather than creating a restriction" do
      p = policy(["", nil, 42], [""])

      refute ToolPolicy.restricted?(p)
      assert ToolPolicy.allowed?(p, "start_session")
    end

    test "an explicit deny-all is spelled [\"*\"] on the denylist" do
      p = policy(nil, ["*"])

      assert ToolPolicy.restricted?(p)
      refute ToolPolicy.allowed?(p, "start_session")
      refute ToolPolicy.allowed?(p, "github__get_issue")
      refute ToolPolicy.allowed?(p, "")
    end

    test "unrestricted/0 is the neutral policy" do
      refute ToolPolicy.restricted?(ToolPolicy.unrestricted())
      assert ToolPolicy.allowed?(ToolPolicy.unrestricted(), "start_session")
    end
  end

  describe "filter/2,3" do
    test "filters string-keyed MCP tool definition maps" do
      tools = [
        %{"name" => "report_progress", "description" => "a"},
        %{"name" => "start_session", "description" => "b"},
        %{"name" => "github__get_issue", "description" => "c"}
      ]

      kept =
        tools
        |> ToolPolicy.filter(policy(nil, ["start_session", "github__*"]))
        |> Enum.map(& &1["name"])

      assert kept == ["report_progress"]
    end

    test "filters atom-keyed code-exec index entries" do
      index = [
        %{name: "report_progress", description: "a", schema: %{}, args: []},
        %{name: "start_session", description: "b", schema: %{}, args: []}
      ]

      kept =
        index
        |> ToolPolicy.filter(policy(["report_progress"], nil))
        |> Enum.map(& &1.name)

      assert kept == ["report_progress"]
    end

    test "an unrestricted policy returns the list untouched" do
      tools = [%{"name" => "a"}, %{"name" => "b"}]
      assert ToolPolicy.filter(tools, ToolPolicy.unrestricted()) == tools
    end

    test "an entry with no readable name is kept rather than silently dropped" do
      tools = [%{"description" => "no name here"}, %{"name" => "start_session"}]

      assert ToolPolicy.filter(tools, policy(nil, ["start_session"])) == [
               %{"description" => "no name here"}
             ]
    end

    test "filter/3 takes an explicit name extractor" do
      tools = [{"a", 1}, {"b", 2}]

      assert ToolPolicy.filter(tools, policy(["a"], nil), &elem(&1, 0)) == [{"a", 1}]
    end
  end

  describe "from_state/1" do
    test "reads a resolved policy off an MCP server state map" do
      p = policy(nil, ["start_session"])
      assert ToolPolicy.from_state(%{tool_policy: p}) == p
    end

    test "a state with no policy is unrestricted — and does NO hub work" do
      assert ToolPolicy.from_state(%{orca_session_id: "whatever"}) ==
               ToolPolicy.unrestricted()

      assert ToolPolicy.from_state(%{}) == ToolPolicy.unrestricted()
      assert ToolPolicy.from_state(nil) == ToolPolicy.unrestricted()
    end
  end

  describe "resolve/1" do
    test "builds the policy from the session's columns" do
      {:ok, session} =
        Sessions.create_session(%{
          directory: "/tmp",
          tool_allowlist: ["report_progress"],
          tool_denylist: ["github__*"]
        })

      assert %ToolPolicy{allow: ["report_progress"], deny: ["github__*"]} =
               ToolPolicy.resolve(session.id)
    end

    test "a session with no policy columns resolves to unrestricted" do
      {:ok, session} = Sessions.create_session(%{directory: "/tmp"})

      assert ToolPolicy.resolve(session.id) == ToolPolicy.unrestricted()
    end

    test "FAIL OPEN: a missing session resolves to unrestricted, not deny-all" do
      assert ToolPolicy.resolve(Ecto.UUID.generate()) == ToolPolicy.unrestricted()
    end

    test "FAIL OPEN: a lookup that RAISES resolves to unrestricted" do
      # A non-UUID id makes the Ecto cast raise inside HubRPC — stands in for
      # any hub/erpc failure; the point is that a raise must never become a
      # restriction.
      assert ToolPolicy.resolve("not-a-uuid") == ToolPolicy.unrestricted()
    end

    test "a nil / non-binary session id resolves to unrestricted" do
      assert ToolPolicy.resolve(nil) == ToolPolicy.unrestricted()
      assert ToolPolicy.resolve(:nope) == ToolPolicy.unrestricted()
    end
  end

  describe "merge/2 (future project-/node-level layering)" do
    test "denylists union and allowlists intersect" do
      a = policy(["a", "b"], ["x"])
      b = policy(["b", "c"], ["y"])

      merged = ToolPolicy.merge(a, b)

      assert merged.allow == ["b"]
      assert Enum.sort(merged.deny) == ["x", "y"]
    end

    test "an empty allowlist yields to the other side's" do
      assert ToolPolicy.merge(policy([], nil), policy(["a"], nil)).allow == ["a"]
      assert ToolPolicy.merge(policy(["a"], nil), policy([], nil)).allow == ["a"]
    end
  end
end
