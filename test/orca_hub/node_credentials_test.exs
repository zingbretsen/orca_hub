defmodule OrcaHub.NodeCredentialsTest do
  use OrcaHub.DataCase

  alias OrcaHub.NodeCredentials

  describe "token store" do
    test "get_token_for_node returns nil when no credential exists" do
      assert NodeCredentials.get_token_for_node("orca@nope") == nil
    end

    test "put_token_for_node inserts and reads back" do
      assert {:ok, _} = NodeCredentials.put_token_for_node("orca@mini", "sk-ant-oat01-abc")
      assert NodeCredentials.get_token_for_node("orca@mini") == "sk-ant-oat01-abc"
    end

    test "put_token_for_node upserts on node_name (no duplicate rows)" do
      {:ok, _} = NodeCredentials.put_token_for_node("orca@mini", "sk-ant-oat01-old")
      {:ok, _} = NodeCredentials.put_token_for_node("orca@mini", "sk-ant-oat01-new")

      assert NodeCredentials.get_token_for_node("orca@mini") == "sk-ant-oat01-new"
      assert NodeCredentials.list_logged_in_nodes() == ["orca@mini"]
    end

    test "delete_for_node removes the credential" do
      {:ok, _} = NodeCredentials.put_token_for_node("orca@mini", "sk-ant-oat01-abc")
      assert {:ok, 1} = NodeCredentials.delete_for_node("orca@mini")
      assert NodeCredentials.get_token_for_node("orca@mini") == nil
    end

    test "list_logged_in_nodes returns only node names, never tokens" do
      {:ok, _} = NodeCredentials.put_token_for_node("orca@a", "sk-ant-oat01-a")
      {:ok, _} = NodeCredentials.put_token_for_node("orca@b", "sk-ant-oat01-b")

      nodes = NodeCredentials.list_logged_in_nodes()
      assert "orca@a" in nodes
      assert "orca@b" in nodes
      refute Enum.any?(nodes, &String.contains?(&1, "sk-ant"))
    end
  end

  describe "token_env/1" do
    test "returns an empty list for nil/empty (don't clobber credentials.json)" do
      assert NodeCredentials.token_env(nil) == []
      assert NodeCredentials.token_env("") == []
    end

    test "returns a charlist env tuple for a real token" do
      assert NodeCredentials.token_env("sk-ant-oat01-xyz") ==
               [{~c"CLAUDE_CODE_OAUTH_TOKEN", ~c"sk-ant-oat01-xyz"}]
    end
  end
end
