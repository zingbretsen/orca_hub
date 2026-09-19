defmodule OrcaHub.ClusterHubRpcBoundaryTest do
  @moduledoc """
  Regression for ORCAHUB3-106: `OrcaHub.Cluster.cascade_archive_session/3`
  called `OrcaHub.Sessions.list_unarchived_descendants/1` directly instead
  of routing through `OrcaHub.HubRPC`, unlike every other DB read/write in
  this module (`get_session!/2`, `archive_session/3`, `runner_node_for/1`'s
  siblings, etc. — see `cluster.ex`'s moduledoc: the hub owns the DB, an
  agent node has none). It raised "could not lookup Ecto repo
  OrcaHub.Repo" on any agent node, before the cascade could even run —
  breaking `archive_session` outright there, for a childless session too.

  This is a STATIC source check, not a runtime one, deliberately: the bug
  is invisible to any functional test run in this suite's normal (single
  local hub-mode node) configuration, because `HubRPC.call/3` on the hub
  branch is just a local `apply/3` — a call that goes through `HubRPC` and
  a call that bypasses it entirely produce byte-identical results when
  `Mode.hub?()` is true. Making it runtime-observable would need a genuine
  second node in agent mode (the `:distributed`-tagged apparatus already
  used elsewhere, e.g. `cluster_distributed_test.exs`, `hub_rpc_test.exs`),
  which is excluded from the default run and wouldn't have caught this
  regression before a deploy either. A static check over `cluster.ex`'s own
  AST runs every time and fails the instant the bypass reappears, in
  `cascade_archive_session/3` or anywhere else in the module.
  """

  use ExUnit.Case, async: true

  @cluster_source Path.expand("../../lib/orca_hub/cluster.ex", __DIR__)

  # Modules OrcaHub.Cluster is allowed to reach directly instead of via
  # HubRPC — struct-only references (no DB access), never grow this for a
  # function call.
  @allowed_alias_targets MapSet.new(["Session"])

  test "ORCAHUB3-106: cluster.ex never calls OrcaHub.Sessions.* or OrcaHub.Repo.* directly — everything DB-facing routes through HubRPC" do
    ast =
      @cluster_source
      |> File.read!()
      |> Code.string_to_quoted!()

    {_ast, violations} = Macro.prewalk(ast, [], &collect_direct_db_calls/2)

    assert violations == [],
           "cluster.ex calls OrcaHub.Sessions/OrcaHub.Repo directly (bypassing HubRPC): " <>
             inspect(Enum.reverse(violations))
  end

  # A remote call `OrcaHub.Sessions.fun(...)` / `OrcaHub.Repo.fun(...)`
  # compiles to {{:., _, [{:__aliases__, _, [:OrcaHub, :Sessions | rest]}, fun]}, meta, args}.
  # `rest == []` is the direct-call violation we're hunting; `rest ==
  # ["Session"]` etc. is a struct reference like `OrcaHub.Sessions.Session`
  # used in a type/pattern position, which has a DIFFERENT (`:%`, not `:.`)
  # AST shape entirely and never reaches this clause — the allowlist here
  # only guards a hypothetical future call ON that submodule.
  defp collect_direct_db_calls(
         {{:., _, [{:__aliases__, _, [:OrcaHub, target | rest]}, fun]}, meta, _args} = node,
         acc
       )
       when target in [:Sessions, :Repo] do
    case rest do
      [] ->
        {node, [{"OrcaHub.#{target}.#{fun}", meta[:line]} | acc]}

      [sub] ->
        if to_string(sub) in @allowed_alias_targets do
          {node, acc}
        else
          {node, [{"OrcaHub.#{target}.#{sub}.#{fun}", meta[:line]} | acc]}
        end

      _ ->
        {node, [{"OrcaHub.#{target}.#{Enum.join(rest, ".")}.#{fun}", meta[:line]} | acc]}
    end
  end

  defp collect_direct_db_calls(node, acc), do: {node, acc}
end
