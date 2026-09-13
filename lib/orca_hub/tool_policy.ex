defmodule OrcaHub.ToolPolicy do
  @moduledoc """
  Per-session MCP tool restrictions — a declarative, ENFORCED replacement for
  the English "you may call X, never call Y" paragraphs operators write into
  trigger/agent prompts (which a model is free to ignore).

  A policy is built from two nullable `sessions` columns:

    * `tool_allowlist` — if non-empty, ONLY tools matching an entry pass the
      allow stage.
    * `tool_denylist` — any tool matching an entry is refused.

  ## Semantics

    * `nil` **or** `[]` for `tool_allowlist` means NO allowlist restriction —
      every tool passes the allow stage. `[]` deliberately does NOT mean "deny
      everything": Phoenix form/multi-select casting turns an untouched field
      into `[]`, and that reading would silently strip every tool from a
      session. An explicit deny-all is spelled `tool_denylist: ["*"]`.
    * `nil` or `[]` for `tool_denylist` means nothing is denied.
    * **Deny wins** over allow.
    * Entries match the RAW MCP tool name — `send_message_to_session`,
      `github__get_issue` — either exactly, or as a glob when the entry
      contains `*`. `*` matches any run of characters, INCLUDING the `__`
      upstream-prefix separator (so `github__*` restricts one upstream server
      and `*` matches everything). Only `*` is supported: no `?`, no character
      classes. Matching is case-sensitive.

  ## Failure direction: FAIL OPEN

  `resolve/1` returns `unrestricted/0` and logs at `:error` if the lookup
  raises (hub blip, erpc failure) or the session is missing. This is an
  operator guardrail against an agent misbehaving, **not** a security boundary
  against an attacker: a transient hub failure that stripped every tool from
  every running session would be far worse than briefly not enforcing a
  restriction. This mirrors `OrcaHub.NodePolicy`'s fail-open posture for
  `isolated`/`scrub_session_env`. Nothing compile-time or static may depend on
  hub reachability — hence `from_state/1`, which never touches the hub and is
  what the enforcement points on the hot path actually call.

  ## No hardcoded exemptions

  There is deliberately no "these tools can never be denied" list. If an
  operator denies `report_progress`, that is their call. The code-exec
  meta-tool `run_elixir` is not part of `OrcaHub.MCP.Tools.list/0` at all (it
  comes from `OrcaHub.MCP.CodeExec.MetaTools`), so it is inherently unaffected
  by a policy without any special-casing — a session can always still *run* a
  snippet, the individual `Tools.*` calls inside it are what get gated.

  ## Where it is enforced

    * `OrcaHub.MCP.Tools.list/1` — first-party `tools/list` visibility.
    * `OrcaHub.MCP.Server`'s standard `tools/list` clause — also filters
      `OrcaHub.MCP.UpstreamClient.list_tools/0`, which `Tools.list/1` doesn't
      cover.
    * `OrcaHub.MCP.Tools.call/3` — refuses a denied first-party tool.
    * `OrcaHub.MCP.CodeExec.Dispatcher.dispatch/3` — refuses a denied tool of
      EITHER kind; upstream calls never reach `Tools.call/3`, so this is the
      only gate covering them on the code-exec path.
    * `OrcaHub.MCP.CodeExec.ToolGen`'s generated `Tools.list/0` /
      `Tools.search/1` / `Tools.schema/1` — so a restricted session doesn't
      SEE tools it can't call.

  A policy is resolved lazily, once per MCP connection, and cached on the MCP
  server state; a mid-session change therefore takes effect on the next COLD
  port re-open, which `SessionRunner` forces via the same `pending_rebake` /
  `evict_warm` path used for the `orchestrator` / `code_exec` flags.

  ## Future layering

  `merge/2` composes two policies (allowlists intersect by the natural
  "must pass both" reading; denylists union), so a project- or node-level
  layer can be folded in later without changing any enforcement point. No such
  layer exists today — `resolve/1` reads only the session row.
  """

  require Logger

  alias OrcaHub.HubRPC

  defstruct allow: [], deny: []

  @type t :: %__MODULE__{allow: [String.t()], deny: [String.t()]}

  @doc "The neutral policy: nothing restricted."
  def unrestricted, do: %__MODULE__{allow: [], deny: []}

  @doc """
  Build a policy from raw allow/deny lists. `nil`, `[]`, and non-list junk all
  normalize to "no restriction" for that side.
  """
  def new(allow, deny) do
    %__MODULE__{allow: normalize(allow), deny: normalize(deny)}
  end

  @doc """
  Build a policy from a session row/map (`:tool_allowlist` / `:tool_denylist`).
  """
  def from_session(%{} = session) do
    new(Map.get(session, :tool_allowlist), Map.get(session, :tool_denylist))
  end

  def from_session(_), do: unrestricted()

  @doc """
  Resolve the policy for an orca session id via `OrcaHub.HubRPC`.

  Fails OPEN (see the moduledoc): a missing session, a nil id, or ANY raise/exit
  during the lookup yields `unrestricted/0`.
  """
  def resolve(nil), do: unrestricted()

  def resolve(session_id) when is_binary(session_id) do
    case HubRPC.get_session(session_id) do
      nil ->
        Logger.error(
          "[tool_policy] no session found for orca_session_id=#{inspect(session_id)} — " <>
            "failing open (unrestricted)"
        )

        unrestricted()

      session ->
        from_session(session)
    end
  rescue
    e ->
      Logger.error(
        "[tool_policy] resolve raised for orca_session_id=#{inspect(session_id)} — failing " <>
          "open (unrestricted): " <> Exception.format(:error, e, __STACKTRACE__)
      )

      unrestricted()
  catch
    kind, reason ->
      Logger.error(
        "[tool_policy] resolve #{kind} for orca_session_id=#{inspect(session_id)} — failing " <>
          "open (unrestricted): " <> Exception.format(kind, reason, __STACKTRACE__)
      )

      unrestricted()
  end

  def resolve(_), do: unrestricted()

  @doc """
  Read an already-resolved policy off an MCP server `state` map.

  Never does hub work: a state with no `:tool_policy` (an old connection, a
  test map, a caller that never went through `tools/list`) is unrestricted.
  Resolution is the MCP server's job — see `OrcaHub.MCP.Server`'s
  `ensure_tool_policy/1`.
  """
  def from_state(%{tool_policy: %__MODULE__{} = policy}), do: policy
  def from_state(_state), do: unrestricted()

  @doc "Whether this policy actually constrains anything."
  def restricted?(%__MODULE__{allow: [], deny: []}), do: false
  def restricted?(%__MODULE__{}), do: true
  def restricted?(_), do: false

  @doc """
  Whether `name` (a raw MCP tool name) is callable under `policy`:
  the allowlist is empty or matches, AND the denylist does not match.
  """
  def allowed?(%__MODULE__{allow: allow, deny: deny}, name) when is_binary(name) do
    (allow == [] or matches?(allow, name)) and not matches?(deny, name)
  end

  def allowed?(%__MODULE__{}, _name), do: false
  def allowed?(_policy, _name), do: true

  @doc """
  Filter a list of tool maps by `policy`, keeping only allowed tools.

  Works for both shapes in play: string-keyed MCP tool definition maps
  (`%{"name" => ...}`) and the atom-keyed index entries the code-exec
  generated helpers carry (`%{name: ...}`). An entry with no recognizable
  name is kept — filtering is not the place to drop a malformed definition.
  """
  def filter(tools, policy) when is_list(tools) do
    filter(tools, policy, &tool_name/1)
  end

  @doc """
  Like `filter/2` but with an explicit name extractor, for a tool shape
  neither default head recognizes.
  """
  def filter(tools, policy, name_fun) when is_list(tools) and is_function(name_fun, 1) do
    if restricted?(policy) do
      Enum.filter(tools, fn tool ->
        case name_fun.(tool) do
          name when is_binary(name) -> allowed?(policy, name)
          # Unnamed/malformed entry: keep it. Filtering by policy is not the
          # place to drop a definition we couldn't read a name off of.
          _ -> true
        end
      end)
    else
      tools
    end
  end

  @doc """
  Compose two policies — "must satisfy both". Allowlists intersect (an empty
  one meaning "no restriction", so it yields to the other); denylists union.
  Unused today; here so a future project-/node-level layer can be folded in
  without touching any enforcement point.
  """
  def merge(%__MODULE__{} = a, %__MODULE__{} = b) do
    allow =
      case {a.allow, b.allow} do
        {[], other} -> other
        {other, []} -> other
        {x, y} -> Enum.filter(x, &matches?(y, &1))
      end

    %__MODULE__{allow: allow, deny: Enum.uniq(a.deny ++ b.deny)}
  end

  @doc """
  The message handed back to a model when a tool call is refused by policy.
  Shared by every enforcement point so the refusal reads identically wherever
  it's caught.
  """
  def denial_message(name) do
    "Tool #{name} is restricted for this session and cannot be called. This session was " <>
      "started with an MCP tool allow/deny policy; #{name} is not permitted by it. Do not " <>
      "retry it — use another tool, or report back that the tool is unavailable."
  end

  # `%{"name" => _}` MCP tool definitions and `%{name: _}` code-exec index
  # entries are both in play; anything else has no name to match on.
  defp tool_name(%{"name" => name}) when is_binary(name), do: name
  defp tool_name(%{name: name}) when is_binary(name), do: name
  defp tool_name(_), do: nil

  defp matches?(_patterns, nil), do: false

  defp matches?(patterns, name) do
    Enum.any?(patterns, &matches_pattern?(&1, name))
  end

  defp matches_pattern?(pattern, name) when is_binary(pattern) do
    if String.contains?(pattern, "*") do
      Regex.match?(glob_regex(pattern), name)
    else
      pattern == name
    end
  end

  defp matches_pattern?(_pattern, _name), do: false

  # `*` (and only `*`) is a wildcard, matching any run of characters including
  # the `__` upstream separator. Everything else is escaped, so a name with
  # regex metacharacters in it can't smuggle in extra matching behaviour.
  defp glob_regex(pattern) do
    source =
      pattern
      |> String.split("*")
      |> Enum.map(&Regex.escape/1)
      |> Enum.join(".*")

    Regex.compile!("\\A" <> source <> "\\z")
  end

  defp normalize(list) when is_list(list) do
    list
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  defp normalize(_), do: []
end
