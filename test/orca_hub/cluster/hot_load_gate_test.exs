defmodule OrcaHub.Cluster.HotLoadGateTest do
  @moduledoc """
  The gate is what makes the hot-deploy fast path trustworthy, so these tests
  are deliberately fixture-driven: every refuse category is exercised with a
  diff shaped like one `git diff` actually produces for this repo (file
  headers, `index` lines, `@@` hunk headers, context lines), not a synthetic
  one-liner. Several real bugs only show up against that shape — most
  notably git putting the enclosing function's source into the `@@` hunk
  header, which a naive line scanner reads as content.

  `async: true` because the module under test is pure: no DB, no processes,
  no filesystem.
  """

  use ExUnit.Case, async: true

  alias OrcaHub.Cluster.HotLoadGate
  alias OrcaHub.Cluster.HotLoadGate.Reason

  doctest OrcaHub.Cluster.HotLoadGate

  # ------------------------------------------------------------------
  # Fixtures — realistic unified diffs
  # ------------------------------------------------------------------

  defp fixture(:mix_lock) do
    """
    diff --git a/mix.lock b/mix.lock
    index 1a2b3c4..5d6e7f8 100644
    --- a/mix.lock
    +++ b/mix.lock
    @@ -30,7 +30,7 @@
       "mime": {:hex, :mime, "2.0.7", "...", [:mix], [], "hexpm", "abc"},
    -  "mint": {:hex, :mint, "1.9.3", "...", [:mix], [], "hexpm", "def"},
    +  "mint": {:hex, :mint, "1.10.0", "...", [:mix], [], "hexpm", "ghi"},
       "nimble_options": {:hex, :nimble_options, "1.1.1", "...", [:mix], [], "hexpm", "jkl"},
    """
  end

  defp fixture(:mix_exs) do
    """
    diff --git a/mix.exs b/mix.exs
    index aaa1111..bbb2222 100644
    --- a/mix.exs
    +++ b/mix.exs
    @@ -18,7 +18,7 @@ defmodule OrcaHub.MixProject do
       def application do
         [
           mod: {OrcaHub.Application, []},
    -      extra_applications: [:logger, :runtime_tools]
    +      extra_applications: [:logger, :runtime_tools, :os_mon]
         ]
       end
    """
  end

  defp fixture(:runtime_exs) do
    """
    diff --git a/config/runtime.exs b/config/runtime.exs
    index ccc3333..ddd4444 100644
    --- a/config/runtime.exs
    +++ b/config/runtime.exs
    @@ -44,6 +44,7 @@ if config_env() == :prod do
       config :orca_hub, OrcaHubWeb.Endpoint,
         url: [host: host, port: 443, scheme: "https"],
    -    http: [ip: {0, 0, 0, 0}, port: port]
    +    http: [ip: {0, 0, 0, 0}, port: port],
    +    check_origin: false
     end
    """
  end

  defp fixture(:migration) do
    """
    diff --git a/priv/repo/migrations/20260921120000_add_hot_pushes.exs b/priv/repo/migrations/20260921120000_add_hot_pushes.exs
    new file mode 100644
    index 0000000..eee5555
    --- /dev/null
    +++ b/priv/repo/migrations/20260921120000_add_hot_pushes.exs
    @@ -0,0 +1,10 @@
    +defmodule OrcaHub.Repo.Migrations.AddHotPushes do
    +  use Ecto.Migration
    +
    +  def change do
    +    alter table(:sessions) do
    +      add :last_hot_push_sha, :string
    +    end
    +  end
    +end
    """
  end

  defp fixture(:assets_js) do
    """
    diff --git a/assets/js/app.js b/assets/js/app.js
    index fff6666..111777 100644
    --- a/assets/js/app.js
    +++ b/assets/js/app.js
    @@ -12,6 +12,7 @@ import { Voice } from "./voice"
     const hooks = {
       Voice,
    +  StickyHeader,
     }
    """
  end

  defp fixture(:application_ex) do
    """
    diff --git a/lib/orca_hub/application.ex b/lib/orca_hub/application.ex
    index 222888..333999 100644
    --- a/lib/orca_hub/application.ex
    +++ b/lib/orca_hub/application.ex
    @@ -31,6 +31,7 @@ defmodule OrcaHub.Application do
         children = [
           OrcaHub.Repo,
           {Phoenix.PubSub, name: OrcaHub.PubSub},
    +      OrcaHub.Cluster.HotPushSweep,
           OrcaHubWeb.Endpoint
         ]
    """
  end

  # A supervision change OUTSIDE application.ex: only the diff body reveals it.
  defp fixture(:supervisor_elsewhere) do
    """
    diff --git a/lib/orca_hub/session_supervisor.ex b/lib/orca_hub/session_supervisor.ex
    index 444aaa..555bbb 100644
    --- a/lib/orca_hub/session_supervisor.ex
    +++ b/lib/orca_hub/session_supervisor.ex
    @@ -14,9 +14,11 @@ defmodule OrcaHub.SessionSupervisor do
       @impl true
       def init(_arg) do
    -    children = [
    -      {Registry, keys: :unique, name: OrcaHub.SessionRegistry}
    -    ]
    +    children = [
    +      {Registry, keys: :unique, name: OrcaHub.SessionRegistry},
    +      {Task.Supervisor, name: OrcaHub.SessionTasks}
    +    ]
     
         Supervisor.init(children, strategy: :one_for_one)
       end
    """
  end

  defp fixture(:defstruct_added_field) do
    """
    diff --git a/lib/orca_hub/session_runner.ex b/lib/orca_hub/session_runner.ex
    index 666ccc..777ddd 100644
    --- a/lib/orca_hub/session_runner.ex
    +++ b/lib/orca_hub/session_runner.ex
    @@ -42,7 +42,7 @@ defmodule OrcaHub.SessionRunner do
       defmodule State do
         @moduledoc false
    -    defstruct [:session_id, :port, :backend, :buffer]
    +    defstruct [:session_id, :port, :backend, :buffer, :last_hot_push_at]
       end
     
       @impl true
    """
  end

  # The trap this gate has to survive: git writes the enclosing source line
  # into the `@@` hunk header, so an unrelated edit inside a struct module
  # carries the word `defstruct` on a line that is NOT a change.
  defp fixture(:hunk_header_mentions_defstruct) do
    """
    diff --git a/lib/orca_hub/voice/session.ex b/lib/orca_hub/voice/session.ex
    index 888eee..999fff 100644
    --- a/lib/orca_hub/voice/session.ex
    +++ b/lib/orca_hub/voice/session.ex
    @@ -18,7 +18,7 @@ defstruct [:id, :phase, :buffer]
       def phase(%__MODULE__{phase: phase}), do: phase
     
    -  def idle?(session), do: phase(session) == :idle
    +  def idle?(session), do: phase(session) in [:idle, :ready]
    """
  end

  defp fixture(:build_info) do
    """
    diff --git a/lib/orca_hub/build_info.ex b/lib/orca_hub/build_info.ex
    index aaabbb..cccddd 100644
    --- a/lib/orca_hub/build_info.ex
    +++ b/lib/orca_hub/build_info.ex
    @@ -60,4 +60,5 @@ defmodule OrcaHub.BuildInfo do
       def sha, do: @sha
       def built_at, do: @built_at
    +  def short_sha, do: String.slice(@sha, 0, 7)
     end
    """
  end

  defp fixture(:dockerfile) do
    """
    diff --git a/Dockerfile b/Dockerfile
    index eee111..fff222 100644
    --- a/Dockerfile
    +++ b/Dockerfile
    @@ -8,7 +8,7 @@ FROM hexpm/elixir:1.18.4-erlang-27.3.4-debian-bookworm-20250520 AS builder
    -RUN apt-get update -y && apt-get install -y build-essential git
    +RUN apt-get update -y && apt-get install -y build-essential git curl
    """
  end

  # The ordinary case the whole feature exists for: a function body changed.
  defp fixture(:plain_function_change) do
    """
    diff --git a/lib/orca_hub/sessions.ex b/lib/orca_hub/sessions.ex
    index 111aaa..222bbb 100644
    --- a/lib/orca_hub/sessions.ex
    +++ b/lib/orca_hub/sessions.ex
    @@ -210,7 +210,10 @@ defmodule OrcaHub.Sessions do
       def list_messages_window(session_id, opts \\\\ []) do
         limit = Keyword.get(opts, :limit, 50)
     
    -    from(m in Message, where: m.session_id == ^session_id, order_by: [desc: m.inserted_at])
    +    from(m in Message,
    +      where: m.session_id == ^session_id,
    +      order_by: [desc: m.inserted_at, desc: m.id]
    +    )
         |> limit(^limit)
         |> Repo.all()
       end
    """
  end

  defp fixture(:heex_template) do
    """
    diff --git a/lib/orca_hub_web/live/session_live/show.html.heex b/lib/orca_hub_web/live/session_live/show.html.heex
    index 333ccc..444ddd 100644
    --- a/lib/orca_hub_web/live/session_live/show.html.heex
    +++ b/lib/orca_hub_web/live/session_live/show.html.heex
    @@ -5,7 +5,7 @@
       <div class="flex items-center gap-2">
    -    <span class="badge">{@session.status}</span>
    +    <span class="badge badge-sm">{@session.status}</span>
       </div>
    """
  end

  defp categories_of({_verdict, reasons}), do: Enum.map(reasons, & &1.category)

  # ------------------------------------------------------------------
  # Allow path
  # ------------------------------------------------------------------

  describe "the allow path" do
    test "an empty change list is hot-loadable" do
      assert {:ok, :hot_loadable} = HotLoadGate.classify([])
    end

    test "an ordinary function-body change is hot-loadable" do
      changes = [{"lib/orca_hub/sessions.ex", fixture(:plain_function_change)}]
      assert {:ok, :hot_loadable} = HotLoadGate.classify(changes)
    end

    test "a .heex template change is hot-loadable and needs no diff content" do
      # Templates compile into their view module, so the beam push carries
      # them; and they can hold neither a defstruct nor a supervision tree,
      # so the missing-diff rule must not fire on a bare path either.
      assert {:ok, :hot_loadable} =
               HotLoadGate.classify([
                 {"lib/orca_hub_web/live/session_live/show.html.heex", fixture(:heex_template)}
               ])

      assert {:ok, :hot_loadable} =
               HotLoadGate.classify(["lib/orca_hub_web/live/session_live/show.html.heex"])
    end

    test "a brand new module is hot-loadable" do
      diff = """
      diff --git a/lib/orca_hub/cluster/hot_push.ex b/lib/orca_hub/cluster/hot_push.ex
      new file mode 100644
      --- /dev/null
      +++ b/lib/orca_hub/cluster/hot_push.ex
      @@ -0,0 +1,5 @@
      +defmodule OrcaHub.Cluster.HotPush do
      +  @moduledoc false
      +  def run, do: :ok
      +end
      """

      assert {:ok, :hot_loadable} =
               HotLoadGate.classify([
                 %{path: "lib/orca_hub/cluster/hot_push.ex", diff: diff, status: :added}
               ])
    end

    test "a non-Elixir, non-asset file (docs) is hot-loadable with no diff at all" do
      assert {:ok, :hot_loadable} = HotLoadGate.classify(["CLAUDE.md", ".context/manifest.md"])
    end

    test "unrelated priv/ paths outside migrations and static are hot-loadable" do
      assert {:ok, :hot_loadable} =
               HotLoadGate.classify(["priv/repo/seeds.exs.sample", "priv/git_sha"])
    end

    test "hot_loadable?/1 and reasons/1 agree with a clean verdict" do
      verdict =
        HotLoadGate.classify([{"lib/orca_hub/sessions.ex", fixture(:plain_function_change)}])

      assert HotLoadGate.hot_loadable?(verdict)
      assert HotLoadGate.reasons(verdict) == []
      assert HotLoadGate.explain(verdict) =~ "no blocking changes"
    end
  end

  # ------------------------------------------------------------------
  # Refuse categories, one describe block each
  # ------------------------------------------------------------------

  describe "category 1: mix.lock (dependency change)" do
    test "refuses with an explanation naming the code path problem" do
      assert {:refuse, [%Reason{} = reason]} =
               HotLoadGate.classify([{"mix.lock", fixture(:mix_lock)}])

      assert reason.category == :dependency_change
      assert reason.path == "mix.lock"
      assert reason.message =~ "code path"
      assert reason.message =~ "full build"
    end

    test "refuses on the bare path too, since the rule never needed the diff" do
      assert {:refuse, [%Reason{category: :dependency_change}]} =
               HotLoadGate.classify(["mix.lock"])
    end
  end

  describe "category 2: mix.exs (build config)" do
    test "refuses on any change, without parsing which part moved" do
      assert {:refuse, [%Reason{} = reason]} =
               HotLoadGate.classify([{"mix.exs", fixture(:mix_exs)}])

      assert reason.category == :build_config
      assert reason.message =~ "application/0"
      assert reason.message =~ "extra_applications"
    end

    test "refuses even for a change that is obviously just a version bump" do
      diff = """
      --- a/mix.exs
      +++ b/mix.exs
      @@ -5,7 +5,7 @@ defmodule OrcaHub.MixProject do
      -      version: "0.1.0",
      +      version: "0.1.1",
      """

      assert {:refuse, [%Reason{category: :build_config}]} =
               HotLoadGate.classify([{"mix.exs", diff}])
    end
  end

  describe "category 3: config/*.exs (compile-time and runtime config)" do
    test "refuses runtime.exs, explaining that it is only read at boot" do
      assert {:refuse, [%Reason{} = reason]} =
               HotLoadGate.classify([{"config/runtime.exs", fixture(:runtime_exs)}])

      assert reason.category == :app_config
      assert reason.message =~ "runtime.exs"
      assert reason.message =~ "restart"
    end

    test "refuses every config file, not just runtime.exs" do
      for path <- ~w(config/config.exs config/dev.exs config/prod.exs config/test.exs) do
        assert {:refuse, [%Reason{category: :app_config, path: ^path}]} =
                 HotLoadGate.classify([path])
      end
    end

    test "a non-.exs file under config/ is not a config change" do
      assert {:ok, :hot_loadable} = HotLoadGate.classify(["config/README.md"])
    end

    test "an .exs file outside config/ is not a config change" do
      assert {:ok, :hot_loadable} =
               HotLoadGate.classify([
                 {"test/orca_hub/sessions_test.exs", fixture(:plain_function_change)}
               ])
    end
  end

  describe "category 4: priv/repo/migrations (schema change)" do
    test "refuses an added migration" do
      assert {:refuse, [%Reason{} = reason]} =
               HotLoadGate.classify([
                 %{
                   path: "priv/repo/migrations/20260921120000_add_hot_pushes.exs",
                   diff: fixture(:migration),
                   status: :added
                 }
               ])

      assert reason.category == :migration
      assert reason.status == :added
      assert reason.message =~ "old schema"
    end

    test "refuses a MODIFIED migration too, not only an added one" do
      # The brief says "added", but editing an existing migration is the same
      # class of hazard (and usually worse). Refuse-if-unsure.
      assert {:refuse, [%Reason{category: :migration}]} =
               HotLoadGate.classify([
                 %{
                   path: "priv/repo/migrations/20260101000000_init.exs",
                   status: :modified,
                   diff: "+ x"
                 }
               ])
    end
  end

  describe "category 5: assets/ and priv/static/ (the browser half)" do
    test "refuses an assets/ change" do
      assert {:refuse, [%Reason{} = reason]} =
               HotLoadGate.classify([{"assets/js/app.js", fixture(:assets_js)}])

      assert reason.category == :frontend_asset
      assert reason.message =~ "esbuild"
    end

    test "refuses a priv/static/ change" do
      assert {:refuse, [%Reason{category: :frontend_asset, path: "priv/static/assets/app.css"}]} =
               HotLoadGate.classify(["priv/static/assets/app.css"])
    end

    test "refuses a colocated-hook change under assets/ even though it is JS next to Elixir" do
      assert {:refuse, [%Reason{category: :frontend_asset}]} =
               HotLoadGate.classify(["assets/js/voice/index.js"])
    end
  end

  describe "category 6: supervision-tree changes" do
    test "refuses application.ex on path alone, with the boot-time explanation" do
      assert {:refuse, [%Reason{} = reason]} =
               HotLoadGate.classify([{"lib/orca_hub/application.ex", fixture(:application_ex)}])

      assert reason.category == :supervision_tree
      assert reason.path == "lib/orca_hub/application.ex"
      assert reason.message =~ "start/2 has already run"
    end

    test "application.ex reports ONE supervision reason, not a path-rule and diff-rule duplicate" do
      {:refuse, reasons} =
        HotLoadGate.classify([{"lib/orca_hub/application.ex", fixture(:application_ex)}])

      assert length(reasons) == 1
    end

    test "refuses a supervisor change in some other module, found only in the diff" do
      assert {:refuse, [%Reason{} = reason]} =
               HotLoadGate.classify([
                 {"lib/orca_hub/session_supervisor.ex", fixture(:supervisor_elsewhere)}
               ])

      assert reason.category == :supervision_tree
      assert reason.path == "lib/orca_hub/session_supervisor.ex"
      assert reason.message =~ "children"
      # The evidence quotes the actual offending lines for the operator.
      assert Enum.any?(reason.evidence, &(&1 =~ "children = ["))
    end

    test "detects each supervision marker independently" do
      markers = [
        "+      def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}",
        "+    Supervisor.init(children, strategy: :rest_for_one)",
        "+    Supervisor.start_link(children, strategy: :one_for_one, name: __MODULE__)",
        "+    DynamicSupervisor.start_link(name: OrcaHub.Workers)",
        "+    children = [OrcaHub.Repo]",
        "+  use Supervisor"
      ]

      for marker <- markers do
        assert {:refuse, [%Reason{category: :supervision_tree}]} =
                 HotLoadGate.classify([{"lib/orca_hub/thing.ex", "@@ -1 +1 @@\n" <> marker}]),
               "expected #{inspect(marker)} to trip the supervision rule"
      end
    end

    test "a REMOVED supervision line trips the rule just like an added one" do
      diff = """
      --- a/lib/orca_hub/cluster/supervisor.ex
      +++ b/lib/orca_hub/cluster/supervisor.ex
      @@ -10,7 +10,6 @@ defmodule OrcaHub.Cluster.Supervisor do
           children = [
             OrcaHub.Cluster.NodeDialer,
      -      OrcaHub.Cluster.HeartbeatSweep,
             OrcaHub.Cluster.Registry
           ]
      """

      assert {:refuse, [%Reason{category: :supervision_tree}]} =
               HotLoadGate.classify([{"lib/orca_hub/cluster/supervisor.ex", diff}])
    end

    test "an ADDED child inside an unchanged children list trips the rule" do
      # The realistic shape: `children = [` itself is untouched context and
      # only the new entry is a + line. The direct patterns see nothing here;
      # the bracket-depth scan is what catches it.
      diff = """
      --- a/lib/orca_hub/cluster/supervisor.ex
      +++ b/lib/orca_hub/cluster/supervisor.ex
      @@ -10,6 +10,7 @@ defmodule OrcaHub.Cluster.Supervisor do
           children = [
             OrcaHub.Cluster.NodeDialer,
      +      OrcaHub.Cluster.HotPushSweep,
             OrcaHub.Cluster.Registry
           ]

           Supervisor.init(children, strategy: :one_for_one)
      """

      assert {:refuse, [%Reason{} = reason]} =
               HotLoadGate.classify([{"lib/orca_hub/cluster/supervisor.ex", diff}])

      assert reason.category == :supervision_tree
      assert Enum.any?(reason.evidence, &(&1 =~ "HotPushSweep"))
    end

    test "a change AFTER the children list closes does not trip the rule" do
      # Bracket depth must come back down at the closing `]`, or every later
      # edit in the same hunk inherits the refusal.
      diff = """
      --- a/lib/orca_hub/cluster/supervisor.ex
      +++ b/lib/orca_hub/cluster/supervisor.ex
      @@ -10,7 +10,7 @@ defmodule OrcaHub.Cluster.Supervisor do
           children = [
             OrcaHub.Cluster.NodeDialer
           ]

      -    Logger.info("starting cluster supervisor")
      +    Logger.debug("starting cluster supervisor")
      """

      assert {:ok, :hot_loadable} =
               HotLoadGate.classify([{"lib/orca_hub/cluster/supervisor.ex", diff}])
    end

    test "bracket depth does not leak across a hunk boundary" do
      # An unbalanced `[` left open at the end of one hunk must not make
      # every changed line in the NEXT hunk look like a children entry.
      diff = """
      --- a/lib/orca_hub/cluster/supervisor.ex
      +++ b/lib/orca_hub/cluster/supervisor.ex
      @@ -10,3 +10,3 @@ defmodule OrcaHub.Cluster.Supervisor do
           children = [
             OrcaHub.Cluster.NodeDialer,
      @@ -80,3 +80,3 @@ defmodule OrcaHub.Cluster.Supervisor do
      -  def name, do: "cluster"
      +  def name, do: "cluster-supervisor"
      """

      assert {:ok, :hot_loadable} =
               HotLoadGate.classify([{"lib/orca_hub/cluster/supervisor.ex", diff}])
    end

    test "a @children module-attribute list counts as a children list too" do
      diff = """
      --- a/lib/orca_hub/workers.ex
      +++ b/lib/orca_hub/workers.ex
      @@ -3,5 +3,6 @@ defmodule OrcaHub.Workers do
        @children [
          OrcaHub.Workers.A,
      +   OrcaHub.Workers.B
        ]
      """

      assert {:refuse, [%Reason{category: :supervision_tree}]} =
               HotLoadGate.classify([{"lib/orca_hub/workers.ex", diff}])
    end

    test "mentioning a supervisor only in unchanged context does not trip the rule" do
      diff = """
      --- a/lib/orca_hub/cluster.ex
      +++ b/lib/orca_hub/cluster.ex
      @@ -10,7 +10,7 @@ defmodule OrcaHub.Cluster do
           children = [OrcaHub.Cluster.NodeDialer]
      -    Logger.info("dialing")
      +    Logger.debug("dialing")
           Supervisor.init(children, strategy: :one_for_one)
      """

      assert {:ok, :hot_loadable} = HotLoadGate.classify([{"lib/orca_hub/cluster.ex", diff}])
    end
  end

  describe "category 7: defstruct (the silent-state-corruption rule)" do
    test "refuses an added struct field, with the lost-process-state explanation" do
      assert {:refuse, [%Reason{} = reason]} =
               HotLoadGate.classify([
                 {"lib/orca_hub/session_runner.ex", fixture(:defstruct_added_field)}
               ])

      assert reason.category == :defstruct_change
      assert reason.message =~ "code_change/3"
      assert reason.message =~ "mid-turn session"
      assert Enum.any?(reason.evidence, &(&1 =~ "defstruct"))
    end

    test "refuses a brand-new defstruct" do
      diff = """
      --- /dev/null
      +++ b/lib/orca_hub/cluster/hot_push/plan.ex
      @@ -0,0 +1,4 @@
      +defmodule OrcaHub.Cluster.HotPush.Plan do
      +  defstruct [:nodes, :modules]
      +end
      """

      assert {:refuse, [%Reason{category: :defstruct_change}]} =
               HotLoadGate.classify([{"lib/orca_hub/cluster/hot_push/plan.ex", diff}])
    end

    test "refuses a REMOVED defstruct field" do
      diff = """
      --- a/lib/orca_hub/voice/session.ex
      +++ b/lib/orca_hub/voice/session.ex
      @@ -5,2 +5,2 @@ defmodule OrcaHub.Voice.Session do
      -  defstruct [:id, :phase, :buffer, :legacy_field]
      +  defstruct [:id, :phase, :buffer]
      """

      assert {:refuse, [%Reason{category: :defstruct_change}]} =
               HotLoadGate.classify([{"lib/orca_hub/voice/session.ex", diff}])
    end

    test "refuses a defstruct with default values written across multiple lines" do
      diff = """
      --- a/lib/orca_hub/backend/capabilities.ex
      +++ b/lib/orca_hub/backend/capabilities.ex
      @@ -8,6 +8,7 @@ defmodule OrcaHub.Backend.Capabilities do
      -  defstruct usage: false,
      -            mcp: false,
      -            plan_mode: false
      +  defstruct usage: false,
      +            mcp: false,
      +            plan_mode: false,
      +            hot_load: false
      """

      assert {:refuse, [%Reason{category: :defstruct_change}]} =
               HotLoadGate.classify([{"lib/orca_hub/backend/capabilities.ex", diff}])
    end

    test "the @@ hunk header's trailing context does NOT trip the rule" do
      # git writes the enclosing source line into the hunk header, so an
      # unrelated one-line edit inside a struct module carries the word
      # "defstruct" on a line that is not a change at all.
      assert {:ok, :hot_loadable} =
               HotLoadGate.classify([
                 {"lib/orca_hub/voice/session.ex", fixture(:hunk_header_mentions_defstruct)}
               ])
    end

    test "a comment or docstring merely mentioning defstruct does not trip the rule" do
      diff = """
      --- a/lib/orca_hub/docs.ex
      +++ b/lib/orca_hub/docs.ex
      @@ -1,3 +1,4 @@
       defmodule OrcaHub.Docs do
      +  # See the defstruct rule in HotLoadGate before adding state here.
         def noop, do: :ok
      """

      assert {:ok, :hot_loadable} = HotLoadGate.classify([{"lib/orca_hub/docs.ex", diff}])
    end
  end

  describe "category 8: build_info.ex" do
    test "refuses, explaining that /api/version would report the compiling host" do
      assert {:refuse, [%Reason{} = reason]} =
               HotLoadGate.classify([{"lib/orca_hub/build_info.ex", fixture(:build_info)}])

      assert reason.category == :build_info
      assert reason.message =~ "/api/version"
      assert reason.message =~ "excluded from the push payload"
    end
  end

  describe "category 9: rel/, Dockerfile, systemd/" do
    test "refuses a Dockerfile change" do
      assert {:refuse, [%Reason{category: :release_plumbing, path: "Dockerfile"}]} =
               HotLoadGate.classify([{"Dockerfile", fixture(:dockerfile)}])
    end

    test "refuses rel/ and systemd/ paths" do
      for path <-
            ~w(rel/vm.args.eex rel/env.sh.eex rel/overlays/bin/server systemd/orca-hub.service systemd/install.sh) do
        assert {:refuse, [%Reason{category: :release_plumbing, path: ^path}]} =
                 HotLoadGate.classify([path])
      end
    end

    test "refuses a suffixed Dockerfile variant" do
      assert {:refuse, [%Reason{category: :release_plumbing}]} =
               HotLoadGate.classify(["Dockerfile.dev"])
    end
  end

  # ------------------------------------------------------------------
  # Missing diff content
  # ------------------------------------------------------------------

  describe "missing diff content" do
    test "an .ex file with no diff refuses rather than being waved through" do
      assert {:refuse, [%Reason{} = reason]} = HotLoadGate.classify(["lib/orca_hub/sessions.ex"])
      assert reason.category == :missing_diff
      assert reason.message =~ "require_diff: false"
    end

    test "require_diff: false downgrades to path-only classification" do
      assert {:ok, :hot_loadable} =
               HotLoadGate.classify(["lib/orca_hub/sessions.ex"], require_diff: false)
    end

    test "require_diff: false still applies every path rule" do
      assert {:refuse, [%Reason{category: :supervision_tree}]} =
               HotLoadGate.classify(["lib/orca_hub/application.ex"], require_diff: false)
    end

    test "a path rule already covers the file, so missing_diff is not piled on top" do
      assert {:refuse, [%Reason{category: :app_config}]} =
               HotLoadGate.classify(["config/dev.exs"])
    end

    test "an empty diff string is content, not a missing diff" do
      assert {:ok, :hot_loadable} = HotLoadGate.classify([{"lib/orca_hub/sessions.ex", ""}])
    end
  end

  # ------------------------------------------------------------------
  # Multi-reason
  # ------------------------------------------------------------------

  describe "multi-reason diffs" do
    test "a change tripping three categories reports all three, not just the first" do
      verdict =
        HotLoadGate.classify([
          {"mix.lock", fixture(:mix_lock)},
          {"config/runtime.exs", fixture(:runtime_exs)},
          {"assets/js/app.js", fixture(:assets_js)}
        ])

      assert {:refuse, reasons} = verdict
      assert categories_of(verdict) == [:dependency_change, :app_config, :frontend_asset]
      assert length(reasons) == 3
    end

    test "one file can trip two DIFFERENT categories at once" do
      # A supervisor module that also grew a struct field: both hazards are
      # real and independent, so both must be reported.
      diff = """
      --- a/lib/orca_hub/cluster/node_dialer.ex
      +++ b/lib/orca_hub/cluster/node_dialer.ex
      @@ -9,7 +9,8 @@ defmodule OrcaHub.Cluster.NodeDialer do
      -  defstruct [:nodes, :interval]
      +  defstruct [:nodes, :interval, :last_error]

      -    children = [OrcaHub.Cluster.NodeDialer.Worker]
      +    children = [OrcaHub.Cluster.NodeDialer.Worker, OrcaHub.Cluster.NodeDialer.Probe]
      """

      verdict = HotLoadGate.classify([{"lib/orca_hub/cluster/node_dialer.ex", diff}])
      assert {:refuse, _} = verdict
      assert categories_of(verdict) == [:supervision_tree, :defstruct_change]
    end

    test "a realistic mixed release: every category in one push" do
      changes = [
        {"mix.lock", fixture(:mix_lock)},
        {"mix.exs", fixture(:mix_exs)},
        {"config/runtime.exs", fixture(:runtime_exs)},
        %{
          path: "priv/repo/migrations/20260921120000_add_hot_pushes.exs",
          diff: fixture(:migration),
          status: :added
        },
        {"assets/js/app.js", fixture(:assets_js)},
        {"lib/orca_hub/application.ex", fixture(:application_ex)},
        {"lib/orca_hub/session_runner.ex", fixture(:defstruct_added_field)},
        {"lib/orca_hub/build_info.ex", fixture(:build_info)},
        {"Dockerfile", fixture(:dockerfile)},
        "lib/orca_hub/mystery.ex",
        {"lib/orca_hub/sessions.ex", fixture(:plain_function_change)}
      ]

      verdict = HotLoadGate.classify(changes)
      assert {:refuse, reasons} = verdict

      # Every category the gate knows about, in the documented report order,
      # and nothing for the two hot-loadable files.
      assert categories_of(verdict) == HotLoadGate.categories()
      assert length(reasons) == length(HotLoadGate.categories())
      refute Enum.any?(reasons, &(&1.path == "lib/orca_hub/sessions.ex"))
    end

    test "reason order is deterministic regardless of input order" do
      a = {"assets/js/app.js", fixture(:assets_js)}
      b = {"mix.lock", fixture(:mix_lock)}
      c = {"lib/orca_hub/build_info.ex", fixture(:build_info)}

      assert categories_of(HotLoadGate.classify([a, b, c])) ==
               categories_of(HotLoadGate.classify([c, a, b]))

      assert categories_of(HotLoadGate.classify([a, b, c])) ==
               [:dependency_change, :frontend_asset, :build_info]
    end

    test "within a category, reasons are ordered by path" do
      verdict = HotLoadGate.classify(["config/test.exs", "config/dev.exs", "config/config.exs"])
      {:refuse, reasons} = verdict

      assert Enum.map(reasons, & &1.path) == [
               "config/config.exs",
               "config/dev.exs",
               "config/test.exs"
             ]
    end
  end

  # ------------------------------------------------------------------
  # Override
  # ------------------------------------------------------------------

  describe "the force override" do
    test "force: true returns :forced and STILL carries every reason" do
      changes = [{"mix.lock", fixture(:mix_lock)}, {"assets/js/app.js", fixture(:assets_js)}]

      assert {:forced, reasons} = HotLoadGate.classify(changes, force: true)
      assert Enum.map(reasons, & &1.category) == [:dependency_change, :frontend_asset]
    end

    test "the forced reasons are byte-identical to what a refusal would have said" do
      changes = [{"lib/orca_hub/session_runner.ex", fixture(:defstruct_added_field)}]

      assert {:refuse, refused} = HotLoadGate.classify(changes)
      assert {:forced, forced} = HotLoadGate.classify(changes, force: true)
      assert refused == forced
    end

    test "force on a clean diff is still a plain ok, not a bogus override" do
      assert {:ok, :hot_loadable} =
               HotLoadGate.classify(
                 [{"lib/orca_hub/sessions.ex", fixture(:plain_function_change)}],
                 force: true
               )
    end

    test "hot_loadable?/1 permits a forced verdict but not a refusal" do
      changes = [{"mix.lock", fixture(:mix_lock)}]
      assert HotLoadGate.hot_loadable?(HotLoadGate.classify(changes, force: true))
      refute HotLoadGate.hot_loadable?(HotLoadGate.classify(changes))
    end

    test "explain/1 of a forced verdict says it was overridden, not resolved" do
      text =
        HotLoadGate.explain(HotLoadGate.classify([{"mix.lock", fixture(:mix_lock)}], force: true))

      assert text =~ "OVERRIDDEN (force: true)"
      assert text =~ "overridden, not resolved"
      assert text =~ "[dependency_change] mix.lock"
    end
  end

  # ------------------------------------------------------------------
  # explain/1
  # ------------------------------------------------------------------

  describe "explain/1" do
    test "renders a refusal as an operator-readable multi-line report" do
      verdict =
        HotLoadGate.classify([
          {"mix.lock", fixture(:mix_lock)},
          {"lib/orca_hub/session_runner.ex", fixture(:defstruct_added_field)}
        ])

      text = HotLoadGate.explain(verdict)

      assert text =~ "Hot load REFUSED: 2 blocking changes across 2 files."
      assert text =~ "[dependency_change] mix.lock"
      assert text =~ "[defstruct_change] lib/orca_hub/session_runner.ex"
      # The evidence lines are quoted so the reader does not have to re-read the diff.
      assert text =~ "> defstruct [:session_id, :port, :backend, :buffer, :last_hot_push_at]"
      assert text =~ "Override with force: true"
      assert String.ends_with?(text, "\n")
      assert length(String.split(text, "\n")) > 6
    end

    test "singular wording for a single reason" do
      text = HotLoadGate.explain(HotLoadGate.classify(["mix.lock"]))
      assert text =~ "1 blocking change across 1 file."
    end

    test "accepts a bare reason list as well as a verdict" do
      {:refuse, reasons} = HotLoadGate.classify(["mix.lock"])
      assert HotLoadGate.explain(reasons) == HotLoadGate.explain({:refuse, reasons})
    end

    test "every reason the gate can emit renders with real prose, not a stub" do
      # Guards against a category being added with an empty/placeholder message.
      {:refuse, reasons} =
        HotLoadGate.classify([
          {"mix.lock", fixture(:mix_lock)},
          {"mix.exs", fixture(:mix_exs)},
          {"config/runtime.exs", fixture(:runtime_exs)},
          {"priv/repo/migrations/20260921120000_add_hot_pushes.exs", fixture(:migration)},
          {"assets/js/app.js", fixture(:assets_js)},
          {"lib/orca_hub/application.ex", fixture(:application_ex)},
          {"lib/orca_hub/session_runner.ex", fixture(:defstruct_added_field)},
          {"lib/orca_hub/build_info.ex", fixture(:build_info)},
          {"Dockerfile", fixture(:dockerfile)},
          "lib/orca_hub/mystery.ex"
        ])

      assert Enum.map(reasons, & &1.category) == HotLoadGate.categories()

      for reason <- reasons do
        assert String.length(reason.message) > 80, "#{reason.category} message is too thin"
        refute reason.message =~ "TODO"
      end
    end
  end

  # ------------------------------------------------------------------
  # Input handling
  # ------------------------------------------------------------------

  describe "input shapes" do
    test "bare path, tuple and map forms are interchangeable" do
      for change <- ["mix.lock", {"mix.lock", nil}, %{path: "mix.lock"}] do
        assert {:refuse, [%Reason{category: :dependency_change, path: "mix.lock"}]} =
                 HotLoadGate.classify([change])
      end
    end

    test "a leading ./ is normalized away" do
      assert {:refuse, [%Reason{category: :dependency_change, path: "mix.lock"}]} =
               HotLoadGate.classify(["./mix.lock"])
    end

    test "surrounding whitespace on a path is trimmed" do
      assert {:refuse, [%Reason{category: :app_config}]} =
               HotLoadGate.classify(["  config/dev.exs\n"])
    end

    test "status defaults to :unknown and is carried through when supplied" do
      assert {:refuse, [%Reason{status: :unknown}]} = HotLoadGate.classify(["mix.lock"])

      assert {:refuse, [%Reason{status: :deleted}]} =
               HotLoadGate.classify([%{path: "mix.lock", status: :deleted}])
    end

    test "categories/0 is the full documented list, in report order" do
      assert HotLoadGate.categories() == [
               :dependency_change,
               :build_config,
               :app_config,
               :migration,
               :frontend_asset,
               :supervision_tree,
               :defstruct_change,
               :build_info,
               :release_plumbing,
               :missing_diff
             ]
    end
  end

  describe "changed_lines/1" do
    test "keeps added and removed lines, drops headers, hunk headers and context" do
      lines = HotLoadGate.changed_lines(fixture(:supervisor_elsewhere))

      refute Enum.any?(lines, &String.starts_with?(&1, "-- a/"))
      refute Enum.any?(lines, &(&1 =~ "@@"))
      refute Enum.any?(lines, &(&1 =~ "Supervisor.init"))
      assert Enum.any?(lines, &(&1 =~ "Task.Supervisor"))
    end

    test "a removed line that merely LOOKS like a file header is kept" do
      # `--- a/foo` is a header; `---- section ----` removed from a doc
      # comment is content. Requiring whitespace after the marker keeps the
      # two apart.
      lines =
        HotLoadGate.changed_lines(
          "--- a/lib/x.ex\n+++ b/lib/x.ex\n@@ -1 +1 @@\n----- divider -----\n"
        )

      assert lines == ["---- divider -----"]
    end

    test "accepts a headerless hunk body" do
      assert HotLoadGate.changed_lines("+  defstruct [:a]\n   context\n-  defstruct []\n") ==
               ["  defstruct [:a]", "  defstruct []"]
    end
  end

  # ------------------------------------------------------------------
  # The gate against its own repo
  # ------------------------------------------------------------------

  describe "against this repo's real paths" do
    test "the gate's own source is hot-loadable, but its Reason struct is not" do
      # Self-check: editing the classifier's logic is a normal code change;
      # editing the Reason struct is exactly the hazard rule 7 describes.
      assert {:ok, :hot_loadable} =
               HotLoadGate.classify([
                 {"lib/orca_hub/cluster/hot_load_gate.ex", "@@ -1 +1 @@\n+  def noop, do: :ok\n"}
               ])

      assert {:refuse, [%Reason{category: :defstruct_change}]} =
               HotLoadGate.classify([
                 {"lib/orca_hub/cluster/hot_load_gate/reason.ex",
                  "@@ -1 +1 @@\n-  defstruct [:category]\n+  defstruct [:category, :hint]\n"}
               ])
    end
  end
end
