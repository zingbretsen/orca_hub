defmodule OrcaHub.Cluster.CodePush do
  @moduledoc """
  The hub's code RECONCILIATION LOOP.

  The hub holds a durable *desired code generation*
  (`OrcaHub.CodeGenerations`). Every node that connects is reconciled
  toward it. That framing — not "deploying" — is the whole design, and the
  behaviour that falls out of it is the point of the feature: a node that
  was powered off for a week, a laptop that is only sometimes on, a pod
  that just restarted, all converge on the desired generation without
  anybody running anything. Drift stops being a thing an operator has to
  notice.

  ## Why a single GenServer

  This process is the ONLY thing that publishes or applies a generation, on
  the hub, which is the only node that owns the database. That makes two
  concurrent hot deploys impossible BY CONSTRUCTION — not by a lease, not
  by a TTL, not by a lock. There is nothing to expire, nothing to reclaim
  after a crash, and no window in which two publishers both believe they
  hold the right to push. **Do not add a lock here.** If a future change
  makes it feel like one is needed, that is a signal that serialization
  leaked out of this process, and the fix is to put it back.

  ## Reconcile triggers

    * **Hub boot.** The hub comes up on whatever code its IMAGE contains,
      reads the stored generation, and applies it to itself before touching
      any agent. This is what makes it safe to stop pinning the hub's image
      to a SHA: the image is a floor, not the truth.
    * **`nodeup`.** `:net_kernel.monitor_nodes/2` fires, and after a short
      settle delay (the remote `:orca_hub` application is often still
      starting when distribution comes up) that node is diffed against the
      generation and sent only what differs.
    * **On demand**, via `reconcile_all/0` / `reconcile_node/1`.

  ## Ordering: a reconcile must never DOWNGRADE a node

  The slow deploy path still exists and still ships real images. So the
  fleet can legitimately be NEWER than the stored generation, and blindly
  reconciling would walk it backwards.

  Every node reports `OrcaHub.BuildInfo.built_at/0` — its IMAGE's build
  time, which stays truthful across hot loads precisely because
  `BuildInfo` is excluded from every payload. A node whose image was built
  AFTER the generation was published is newer, and is skipped.

  The hub applies that check to ITSELF first, and it is not merely a
  per-node skip there: if the HUB's image is newer than the generation, the
  generation is stale fleet-wide, and the whole reconcile is abandoned
  rather than continuing to push old code at agents. The generation is left
  in place and reported as `:stale` — superseding it is an explicit
  operator action (`supersede/1`), because "a new image landed" is a fact
  about the world that the hub should not infer and act on by itself.

  A node that cannot be asked for its build time (unreachable, or an
  unparseable value) is reconciled rather than skipped. That is a
  deliberate asymmetry: the overwhelmingly common real case is a STALE
  node — the one that today is missing 250 of 277 modules — and refusing to
  reconcile whenever the evidence is merely absent would make the feature
  useless for exactly the nodes that need it most. An unreachable node's
  push then fails on its own and is reported.

  ## The payload is ALWAYS a full compiled ebin — never a hand-picked list

  `collect_payload/1` reads every `.beam` in the ebin directory and lets the
  md5 diff decide what actually moves. It must stay that way, and the reason
  is not efficiency — it is correctness for a failure mode nothing else in
  this system can see.

  A module attribute that other modules read at COMPILE time (a shared
  `@constant` consumed through a macro, a `@behaviour` callback list) needs
  its CONSUMERS recompiled, not just the file that changed.
  `OrcaHub.Cluster.HotLoadGate` cannot know that: it classifies a diff, and
  the diff shows one file. What closes the hole is `mix compile` itself —
  it already recompiles every dependent, so their beams change, so their
  md5s change, so the diff picks them up and they ship.

  That safety is a property of diffing the FULL build output. Deriving the
  payload from the git diff instead — pushing "just the modules whose source
  changed" — would look like an obvious optimisation, would pass every test
  here, and would silently ship a module whose callers still hold the old
  inlined constant. Do not do it.

  ## Payload provenance: a compile this code performed or verified

  **A payload is only ever the output of a compile this code performed or
  verified — never whatever happened to be on disk.**

  `collect_payload/1` therefore runs `MIX_ENV=prod mix compile` in the
  checkout itself rather than trusting a pre-existing `_build/prod`, and
  then checks what it got.

  The check exists because compiling is not on its own sufficient. Mix
  decides whether to recompile from its own manifest, which tracks the
  Elixir version and the OTP RELEASE (`"27"`) — not the full ERTS version.
  So a host that drifts from OTP 27.3.4 (erts-15.2.7.9) to the pinned
  27.2.3 (erts-15.2.2) keeps the same OTP release, Mix considers every
  existing beam up to date, and `mix compile` does nothing at all. The tree
  stays a mix of beams from two toolchains and looks freshly built.

  Nothing else in the system can see that. `CodeSync.compatible?/1`
  compares LIVE RUNTIMES — the publishing node's against the target's — and
  a `.beam` file carries no ERTS stamp, so a stale artifact passes the ERTS
  gate while being exactly the wrong bytes.

  What a beam DOES carry is its `compile_info` chunk, naming the Erlang
  compiler that produced it. So after compiling, every beam in the payload
  must agree on that version AND agree with the publishing runtime's own
  compiler. A mismatch triggers one automatic `mix compile --force`; if the
  payload is still not homogeneous after that, publishing REFUSES.

  The escalation is deliberately automatic rather than a flag: the day this
  matters is the day someone's toolchain quietly moved, which is precisely
  the day nobody knows to pass a flag. The compiler version that survives
  the check is recorded on the generation (`compiler_version`), so the
  question "what actually built these bytes" has a durable answer rather
  than one reconstructed from whoever happened to publish.

  This is a verifier, not a proof: two OTP patch releases can ship the same
  compiler version, so the check can pass on a genuinely mixed tree. It is
  the strongest signal the artifacts themselves carry. The real guarantee
  is the compile; this catches the case where that compile silently did
  nothing.

  ## Orphaned modules are REPORTED, never purged automatically

  Hot loading cannot un-load a module. A module deleted from source stays
  resident and callable on every node that ever had it, and no amount of
  pushing the new generation removes it.

  Refusing the hot path on a deletion was considered and rejected:
  refactors delete modules constantly, and that rule would make the fast
  path useless for ordinary work. Most genuinely dangerous deletions trip
  the gate's supervision-tree rule anyway.

  So a reconcile reports them as their own category — `orphaned`, kept
  distinct from `missing` and `drifted` because the remedy is different and
  destructive — and removal is an explicit operator action
  (`purge_orphaned/1`). Note `OrcaHub.BuildInfo` is deliberately in no
  generation ever, so it would read as permanently orphaned; it is excluded
  from the orphan set for exactly that reason.

  ## Known hole: a macro-generated struct with no migration

  The gate refuses any `defstruct` change, because hot loading swaps code
  and leaves existing process state at the OLD shape. A struct generated by
  a macro has the identical hazard and is NOT detectable from a diff — most
  importantly an Ecto `schema do ... end` block.

  In practice an Ecto field change ships with a migration, and the gate
  refuses on migrations. The residual hole is a schema change with NO
  migration — adding a `field ..., virtual: true` is the clearest example.
  That would pass the gate, hot-load fine, and crash any long-lived process
  holding an old-shaped struct of that schema on its next message.

  This is documented rather than solved, here and in the gate. Detecting it
  means understanding the macro, not grepping a diff. If a schema change
  without a migration is ever the thing being shipped, use the slow deploy
  path.

  ## Circuit breaker

  This is the sharpest risk in the design and the mechanism deserves to be
  read in full. A bad stored generation that crashes the hub on boot
  produces a CrashLoopBackOff whose only remedy lives inside the thing that
  will not stay up. The fix cannot be "an operator intervenes", because the
  operator's tools are in the crashing process. It has to be automatic.

  Two independent escapes:

  **1. The env hatch.** `ORCA_SKIP_CODE_RECONCILE=1` boots on pure image
  code and applies nothing, ever. This is the manual lever, for the case
  where someone already knows what is wrong. It is intentionally an
  environment variable and not a database flag — a database flag would live
  behind the same database the crashing hub may not reach.

  **2. The apply budget, which needs no operator at all.** A generation is
  not treated as known-good just because it was published. It is `pending`
  until the hub has applied it AND stayed alive for
  `health_window_ms/0` afterwards, at which point it is marked `healthy`.

  The load-bearing detail is ordering: `apply_attempts` is incremented and
  COMMITTED *before* the beams are applied, never after. A counter that
  only advanced on success would record zero attempts in exactly the
  scenario it exists for — the apply killing the process that would have
  written it. Because the increment is already durable, a hub that dies
  mid-apply wakes up knowing it tried.

  So each boot spends one unit of a small budget, and only a generation
  that proves healthy earns the budget back (`mark_healthy/1` resets the
  counter along with the status). A generation that crashes the hub
  therefore exhausts its budget within a couple of restarts and
  `quarantine`s itself — after which the hub boots clean on image code with
  no help from anyone. The CrashLoopBackOff resolves itself.

  Marking healthy resets the counter rather than latching the status
  permanently because a generation that was healthy on one image is not
  necessarily healthy on the next: the hub can be redeployed underneath it.
  A previously-healthy generation that starts crashing burns its refreshed
  budget and quarantines just like a new one.

  The budget deliberately errs toward giving up. A hub that crashes twice
  for an UNRELATED reason inside the health window will quarantine a
  perfectly good generation. That is the correct direction to be wrong in:
  the cost is one slow deploy to re-establish the fleet, against a hub that
  cannot boot.
  """

  use GenServer

  require Logger

  alias OrcaHub.Cluster.{BeamTransport, HotLoadGate}
  alias OrcaHub.CodeGenerations

  @name __MODULE__

  # See the circuit-breaker section of the moduledoc. Two attempts, then
  # quarantine: enough to absorb a single unlucky restart, few enough that a
  # genuinely fatal generation is out of the way within one backoff cycle.
  @max_apply_attempts 2
  @health_window_ms 30_000

  # A `nodeup` fires when DISTRIBUTION comes up, which on a booting node is
  # well before `:orca_hub` has started — `BuildInfo` and `:code` would be
  # interrogated mid-boot. Wait for the node to finish coming up.
  @nodeup_settle_ms 5_000

  @env_hatch "ORCA_SKIP_CODE_RECONCILE"

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  # `:name` is overridable so a test can run its own instance alongside the
  # application's (which is inert under `:code_reconcile_enabled` false)
  # without colliding on the registered name. Every public function below
  # targets the default name; tests call `GenServer.call/3` on their own.
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, @name)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Stores `payload` as the new desired generation and reconciles the fleet.

  `payload` is what `collect_payload/1` produced on the node that owns the
  checkout — see that function. Returns `{:ok, summary}` or
  `{:error, reason}`.
  """
  def publish(payload, opts \\ []) do
    GenServer.call(@name, {:publish, payload, opts}, :timer.minutes(5))
  end

  @doc "Reconcile every currently-connected node against the generation."
  def reconcile_all(opts \\ []) do
    GenServer.call(@name, {:reconcile_all, opts}, :timer.minutes(5))
  end

  @doc "Reconcile one node against the generation."
  def reconcile_node(target, opts \\ []) when is_atom(target) do
    GenServer.call(@name, {:reconcile_node, target, opts}, :timer.minutes(2))
  end

  @doc """
  Supersedes the current generation: the explicit operator action to run
  after a real image deploy lands and the fleet is genuinely newer.

  Deliberately not automatic. See the ordering section of the moduledoc.
  """
  def supersede(note \\ nil), do: GenServer.call(@name, {:supersede, note}, 30_000)

  @doc """
  Unloads every module `target` still carries that the current generation
  does not contain — the explicit operator action for modules deleted from
  source, which hot loading alone can never remove.

  Never automatic, and never kills a process to do it. See the orphaned-
  modules section of the moduledoc.
  """
  def purge_orphaned(target) when is_atom(target),
    do: GenServer.call(@name, {:purge_orphaned, target}, :timer.minutes(2))

  @doc "Current generation + last reconcile outcome per node, for reporting."
  def status, do: GenServer.call(@name, :status, 30_000)

  @doc "How long the hub must stay up after applying before a generation is trusted."
  def health_window_ms,
    do: Application.get_env(:orca_hub, :code_push_health_window_ms, @health_window_ms)

  @doc "Whether reconciliation runs at all on this node."
  def enabled? do
    Application.get_env(:orca_hub, :code_reconcile_enabled, true) and
      System.get_env(@env_hatch) not in ["1", "true", "yes"]
  end

  # ------------------------------------------------------------------
  # Payload collection — runs on the node that owns the checkout
  # ------------------------------------------------------------------

  @doc """
  Gathers a publishable payload from a checkout on THIS node.

  The origin of a publish must be a node that owns a checkout (in practice
  the local Debian systemd agent). Note the topology this has to respect:
  the cluster runs `connect_all false`, so an agent's `Node.list/0` contains
  only the hub. An agent therefore cannot fan out to its peers at all — it
  publishes TO the hub, and the hub fans out. This function is the agent's
  half, and it deliberately does no pushing.

  Options:

    * `:dir` — the checkout (default: cwd)
    * `:ebin` — beams to publish (default: `<dir>/_build/prod/lib/orca_hub/ebin`)
    * `:base` — git ref the change set is measured against, for the
      `OrcaHub.Cluster.HotLoadGate` classification. Resolved by the caller,
      since "what is the fleet currently running" is hub knowledge.
    * `:allow_dirty` — publish from a tree with uncommitted changes
    * `:force` — publish despite a `HotLoadGate` refusal

  ## Dirty checkouts are refused

  A dirty tree is refused unless `:allow_dirty` is set, and when it IS set
  the generation records `dirty: true` forever, so drift reporting can say
  plainly that the fleet is running uncommitted code. Dirty must never pass
  silently: the beams being published would then correspond to no commit
  anywhere, and `base_sha` — the only other provenance the generation
  carries — would be an outright lie about their contents.

  Untracked files count as dirty. They are the likeliest way a sibling
  working in the same tree contributes code to a build nobody meant to
  publish.
  """
  def collect_payload(opts \\ []) do
    dir = Keyword.get(opts, :dir, File.cwd!())
    ebin = Keyword.get(opts, :ebin, Path.join(dir, "_build/prod/lib/orca_hub/ebin"))

    with {:ok, base_sha} <- git_head(dir),
         {:ok, dirty?} <- git_dirty?(dir),
         :ok <- check_dirty(dirty?, Keyword.get(opts, :allow_dirty, false)),
         {:ok, verdict} <- gate_verdict(dir, Keyword.get(opts, :base), opts),
         {:ok, entries, compiler_version} <- build_payload(dir, ebin, opts) do
      {:ok,
       %{
         entries: BeamTransport.sanitize(entries),
         base_sha: base_sha,
         dirty: dirty?,
         erts_version: List.to_string(:erlang.system_info(:version)),
         otp_release: List.to_string(:erlang.system_info(:otp_release)),
         elixir_version: System.version(),
         compiler_version: compiler_version,
         published_from_node: to_string(node()),
         forced_reasons: forced_reasons(verdict),
         ebin: ebin
       }}
    end
  end

  # ------------------------------------------------------------------
  # Payload provenance: compile it, then prove what compiled it
  # ------------------------------------------------------------------

  # Compiles the checkout and returns a payload only if every beam in it
  # agrees on its compiler — see the payload-provenance section of the
  # moduledoc for why a pre-existing _build cannot be trusted.
  #
  # The escalation is deliberate: an ordinary publish pays a cheap
  # incremental compile, a tree poisoned by a toolchain change pays one
  # forced recompile automatically, and a tree that is still heterogeneous
  # after that refuses rather than shipping. Nobody has to know to pass a
  # flag on the day it matters.
  defp build_payload(dir, ebin, opts) do
    with :ok <- maybe_compile(dir, opts) do
      case verified_payload(ebin) do
        {:ok, _entries, _version} = ok ->
          ok

        {:error, {:mixed_payload, _} = reason} ->
          if Keyword.get(opts, :compile, true) do
            Logger.warning(
              "CodePush: #{describe_provenance_error(reason)} — forcing a full recompile."
            )

            with :ok <- compile(dir, ["compile", "--force"]), do: verified_payload(ebin)
          else
            {:error, reason}
          end

        {:error, _} = error ->
          error
      end
    end
  end

  defp maybe_compile(dir, opts) do
    cond do
      not Keyword.get(opts, :compile, true) -> :ok
      Keyword.get(opts, :force_compile, false) -> compile(dir, ["compile", "--force"])
      true -> compile(dir, ["compile"])
    end
  end

  defp compile(dir, args) do
    case System.cmd("mix", args, cd: dir, env: [{"MIX_ENV", "prod"}], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, code} -> {:error, {:compile_failed, code, String.trim(out)}}
    end
  rescue
    e -> {:error, {:compile_failed, :exception, Exception.message(e)}}
  end

  # Reads the payload and asserts every beam names the SAME compiler, and
  # that it is this runtime's compiler. The second half is the one that
  # catches a stale artifact: a beam left over from a different toolchain
  # carries that toolchain's compiler version in its own `compile_info`
  # chunk, which no amount of comparing live runtimes can reveal.
  defp verified_payload(ebin) do
    with {:ok, entries} <- BeamTransport.load_beams(ebin),
         {:ok, version} <- BeamTransport.payload_compiler_version(entries) do
      expected = BeamTransport.local_compiler_version()

      if version == expected do
        {:ok, entries, version}
      else
        {:error, {:mixed_payload, {:runtime_mismatch, version, expected}}}
      end
    end
  end

  @doc false
  def describe_provenance_error({:compile_failed, code, out}),
    do: "`MIX_ENV=prod mix compile` failed (exit #{code}):\n#{out}"

  def describe_provenance_error({:mixed_payload, {:runtime_mismatch, found, expected}}),
    do:
      "the compiled beams were produced by Erlang compiler #{found}, but this node runs " <>
        "compiler #{expected} — the payload is a stale artifact from a different toolchain"

  def describe_provenance_error({:mixed_payload, {:heterogeneous, versions}}),
    do:
      "the payload mixes beams from #{length(versions)} different Erlang compilers " <>
        "(#{Enum.join(versions, ", ")}) — part of _build is stale"

  def describe_provenance_error(other), do: inspect(other)

  defp check_dirty(false, _allow), do: :ok
  defp check_dirty(true, true), do: :ok

  defp check_dirty(true, false),
    do:
      {:error,
       {:dirty_checkout,
        "the checkout has uncommitted or untracked changes. Publishing would ship beams " <>
          "that correspond to no commit. Commit them, or pass allow_dirty to publish anyway " <>
          "(the generation will be permanently marked dirty)."}}

  # A nil base means there is nothing to diff against — no current
  # generation and no usable image SHA. Classify nothing rather than
  # inventing a base: an arbitrary fallback (HEAD~1, say) would produce a
  # verdict about a change set that is not the one being published, which is
  # worse than no verdict because it LOOKS like the gate ran.
  defp gate_verdict(_dir, nil, _opts), do: {:ok, {:ok, :no_base}}

  defp gate_verdict(dir, base, opts) do
    case HotLoadGate.GitDiff.changes(base, dir: dir) do
      {:ok, changes} ->
        verdict = HotLoadGate.classify(changes, force: Keyword.get(opts, :force, false))

        if HotLoadGate.hot_loadable?(verdict) do
          {:ok, verdict}
        else
          {:error, {:gate_refused, HotLoadGate.explain(verdict), HotLoadGate.reasons(verdict)}}
        end

      {:error, reason} ->
        {:error, {:gate_unavailable, reason}}
    end
  end

  defp forced_reasons({:forced, reasons}) do
    Enum.map(reasons, fn r ->
      %{
        "category" => to_string(r.category),
        "path" => r.path,
        "status" => to_string(r.status),
        "message" => r.message,
        "evidence" => r.evidence
      }
    end)
  end

  defp forced_reasons(_), do: []

  defp git_head(dir) do
    case git(["rev-parse", "HEAD"], dir) do
      {:ok, out} -> {:ok, String.trim(out)}
      error -> error
    end
  end

  defp git_dirty?(dir) do
    case git(["status", "--porcelain"], dir) do
      {:ok, out} -> {:ok, String.trim(out) != ""}
      error -> error
    end
  end

  defp git(args, dir) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {out, 0} ->
        {:ok, out}

      {out, code} ->
        {:error, {:git_failed, "git #{Enum.join(args, " ")} exited #{code}: #{String.trim(out)}"}}
    end
  rescue
    e -> {:error, {:git_failed, Exception.message(e)}}
  end

  # ------------------------------------------------------------------
  # GenServer
  # ------------------------------------------------------------------

  @impl true
  def init(opts) do
    if Keyword.get(opts, :monitor_nodes, true),
      do: :net_kernel.monitor_nodes(true, node_type: :all)

    # Boot reconcile runs OUT of init so the supervision tree finishes
    # starting first: applying a generation is a multi-second operation, and
    # doing it inline would stall every sibling child behind it.
    send(self(), :boot_reconcile)

    {:ok, %{last: %{}, booted_at: DateTime.utc_now(), applied_generation_id: nil}}
  end

  @impl true
  def handle_info(:boot_reconcile, state) do
    cond do
      not enabled?() ->
        Logger.warning(
          "CodePush: reconciliation DISABLED (#{@env_hatch} set, or :code_reconcile_enabled " <>
            "false). Booting on pure image code; no generation will be applied."
        )

        {:noreply, state}

      true ->
        {:noreply, boot_reconcile(state)}
    end
  end

  def handle_info({:nodeup, target, _info}, state) do
    Process.send_after(self(), {:settled_nodeup, target}, @nodeup_settle_ms)
    {:noreply, state}
  end

  def handle_info({:nodedown, _target, _info}, state), do: {:noreply, state}

  def handle_info({:settled_nodeup, target}, state) do
    if enabled?() and target in Node.list() do
      {_result, state} = do_reconcile_node(target, [], state)
      {:noreply, state}
    else
      {:noreply, state}
    end
  end

  def handle_info({:confirm_healthy, generation_id}, state) do
    # Reaching this message AT ALL is the proof: it was scheduled before the
    # beams were applied and the hub is still the same process, still
    # processing its mailbox, `health_window_ms/0` later.
    case CodeGenerations.mark_healthy(generation_id) do
      {:ok, generation} ->
        Logger.info(
          "CodePush: generation #{generation_id} (#{generation.base_sha}) proven healthy " <>
            "after #{health_window_ms()}ms; apply budget reset."
        )

      {:error, :not_pending} ->
        :ok
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call({:publish, payload, opts}, _from, state) do
    {result, state} = do_publish(payload, opts, state)
    {:reply, result, state}
  end

  def handle_call({:reconcile_all, opts}, _from, state) do
    {result, state} = do_reconcile_all(opts, state)
    {:reply, result, state}
  end

  def handle_call({:reconcile_node, target, opts}, _from, state) do
    {result, state} = do_reconcile_node(target, opts, state)
    {:reply, result, state}
  end

  def handle_call({:purge_orphaned, target}, _from, state) do
    {:reply, do_purge_orphaned(target), state}
  end

  def handle_call({:supersede, note}, _from, state) do
    case CodeGenerations.current() do
      nil ->
        {:reply, {:error, :no_generation}, state}

      generation ->
        {:ok, superseded} = CodeGenerations.supersede(generation, note)

        Logger.info(
          "CodePush: generation #{superseded.id} (#{superseded.base_sha}) superseded. " <>
            "The fleet will no longer be reconciled toward it."
        )

        {:reply, {:ok, CodeGenerations.summarize(superseded)}, %{state | last: %{}}}
    end
  end

  def handle_call(:status, _from, state) do
    generation = CodeGenerations.current()

    {:reply,
     %{
       enabled: enabled?(),
       generation: CodeGenerations.summarize(generation),
       latest: CodeGenerations.summarize(CodeGenerations.latest()),
       applied_generation_id: state.applied_generation_id,
       health_window_ms: health_window_ms(),
       max_apply_attempts: @max_apply_attempts,
       connected_nodes: Enum.map(Node.list(), &to_string/1),
       last_reconcile: state.last
     }, state}
  end

  # ------------------------------------------------------------------
  # Boot
  # ------------------------------------------------------------------

  defp boot_reconcile(state) do
    case CodeGenerations.current() do
      nil ->
        Logger.info("CodePush: no stored generation; fleet runs pure image code.")
        state

      generation ->
        case breaker_decision(generation) do
          {:quarantine, why} ->
            quarantine(generation, why)
            state

          {:skip, reason} ->
            Logger.warning(
              "CodePush: NOT applying generation #{generation.id} (#{generation.base_sha}): #{reason}"
            )

            state

          :apply ->
            apply_to_self_then_fleet(generation, state)
        end
    end
  end

  # The circuit breaker's decision function. Kept separate from the code
  # that acts on it so the policy is readable — and testable — on its own.
  defp breaker_decision(generation) do
    cond do
      generation.status == "quarantined" ->
        {:skip, "it is quarantined (exhausted its apply budget without ever proving healthy)"}

      generation.status == "superseded" ->
        {:skip, "it has been superseded"}

      # The budget is spent, and the generation still has not proven healthy.
      # Quarantine rather than merely skipping: a generation that is silently
      # ignored on every boot would still be reported as the current one, so
      # `code_generation_status` would tell an operator the fleet is being
      # reconciled toward something nothing is applying. Moving it to a
      # terminal state makes `current/0` fall through to nil, which is the
      # truth — the fleet is on image code.
      generation.apply_attempts >= @max_apply_attempts ->
        {:quarantine,
         "exhausted its apply budget (#{generation.apply_attempts}/#{@max_apply_attempts}) " <>
           "without ever proving healthy"}

      true ->
        :apply
    end
  end

  defp apply_to_self_then_fleet(generation, state) do
    case newer_than_generation?(node(), generation) do
      true ->
        Logger.warning(
          "CodePush: this hub's image (built after generation #{generation.id} / " <>
            "#{generation.base_sha} was published) is NEWER than the stored generation. " <>
            "Skipping the whole reconcile rather than walking the fleet backwards. " <>
            "Run the supersede action to clear it."
        )

        state

      false ->
        state = self_apply(generation, state)
        {_result, state} = do_reconcile_all([], state)
        state
    end
  end

  # Applies a generation to the hub itself, spending one unit of the apply
  # budget FIRST — see the circuit-breaker section of the moduledoc for why
  # the increment has to be durable before the beams land.
  defp self_apply(generation, state) do
    generation = CodeGenerations.record_apply_attempt(generation)

    Logger.info(
      "CodePush: applying generation #{generation.id} (#{generation.base_sha}, " <>
        "#{generation.module_count} modules, attempt #{generation.apply_attempts}/" <>
        "#{@max_apply_attempts}) to this hub."
    )

    # Scheduled BEFORE the apply: if the apply kills this process the timer
    # dies with it and the generation never gets marked healthy, which is
    # precisely the outcome we want.
    Process.send_after(self(), {:confirm_healthy, generation.id}, health_window_ms())

    {result, state} = do_reconcile_node(node(), [self: true], state)
    log_node_result(node(), result)

    %{state | applied_generation_id: generation.id}
  end

  defp quarantine(generation, why) do
    {:ok, _} = CodeGenerations.quarantine(generation, why)

    Logger.error(
      "CodePush: QUARANTINED generation #{generation.id} (#{generation.base_sha}) — #{why}. " <>
        "This hub and the fleet will run pure image code until a new generation is published."
    )
  end

  # ------------------------------------------------------------------
  # Reconcile
  # ------------------------------------------------------------------

  defp do_reconcile_all(opts, state) do
    case CodeGenerations.current() do
      nil ->
        {{:error, :no_generation}, state}

      generation ->
        {results, state} =
          Enum.reduce(Node.list(), {%{}, state}, fn target, {acc, st} ->
            {result, st} = reconcile_against(generation, target, opts, st)
            {Map.put(acc, target, result), st}
          end)

        {{:ok, %{generation: CodeGenerations.summarize(generation), nodes: results}}, state}
    end
  end

  defp do_reconcile_node(target, opts, state) do
    case CodeGenerations.current() do
      nil -> {{:error, :no_generation}, state}
      generation -> reconcile_against(generation, target, opts, state)
    end
  end

  defp reconcile_against(generation, target, opts, state) do
    result = reconcile_one(generation, target, opts)
    log_node_result(target, result)

    entry = Map.put(result, :at, DateTime.utc_now())
    {result, %{state | last: Map.put(state.last, to_string(target), entry)}}
  end

  defp reconcile_one(generation, target, opts) do
    with :ok <- check_erts(generation, target),
         :ok <- check_not_newer(generation, target, opts) do
      manifest = CodeGenerations.manifest(generation.id)

      diff_entries =
        Enum.map(manifest, fn {mod, md5} -> %{module: String.to_atom(mod), md5: md5} end)

      case BeamTransport.drift(diff_entries, target) do
        {:ok, %{missing: missing, drifted: drifted} = report} ->
          needed = missing ++ drifted

          generation
          |> push_needed(target, needed, report)
          |> Map.put(:orphaned, orphaned_modules(generation, target) |> Enum.map(&to_string/1))

        {:error, reason} ->
          %{status: :error, reason: "drift check failed: #{BeamTransport.describe_error(reason)}"}
      end
    end
  end

  defp push_needed(_generation, _target, [], report) do
    %{status: :in_sync, identical: length(report.identical), pushed: 0}
  end

  defp push_needed(generation, target, needed, _report) do
    entries = generation.id |> CodeGenerations.fetch_beams(needed) |> BeamTransport.sanitize()

    # allow_erts_mismatch: true is NOT a weakening here. CodeSync's own gate
    # compares the LOCAL node's ERTS to the target's, which is the wrong
    # pair when the beams come from a stored generation — check_erts/2 above
    # has already compared the GENERATION's ERTS to the target's, which is
    # the right one. See OrcaHub.Cluster.BeamTransport's moduledoc.
    case BeamTransport.push(entries, target, allow_erts_mismatch: true) do
      {:ok, report} ->
        %{
          status: if(report.errors == [], do: :reconciled, else: :partial),
          pushed: length(report.loaded),
          loaded: Enum.map(report.loaded, &to_string/1),
          wedged: Enum.map(report.wedged, &to_string/1),
          skipped_identical: length(report.skipped_identical),
          errors: report.errors
        }

      {:error, reason} ->
        %{status: :error, reason: "push failed: #{BeamTransport.describe_error(reason)}"}
    end
  end

  defp check_erts(generation, target) do
    expected = generation.erts_version

    case BeamTransport.erts_version(target) do
      {:ok, remote} ->
        # erts_verdict/2 rather than a local `==`: the bar for
        # generation-vs-target must be literally the same exact-equality
        # rule CodeSync applies local-vs-target, not a second implementation
        # of it that can drift.
        case BeamTransport.erts_verdict(expected, remote) do
          :ok ->
            :ok

          {:error, {:erts_mismatch, _, _}} ->
            # Deliberately not CodeSync.describe_error/1 here, though it
            # renders this exact tuple: its prose says "this node compiles
            # with erts-X", which is true for a push and false for a
            # reconcile. The beams came from a stored generation, possibly
            # built on a machine that is no longer connected — naming the
            # hub's own toolchain would point an operator at the wrong box.
            %{
              status: :skipped,
              reason:
                "ERTS mismatch: generation was compiled on erts-#{expected}, " <>
                  "#{target} runs erts-#{remote}"
            }
        end

      {:error, reason} ->
        %{
          status: :error,
          reason: "could not read ERTS version: #{BeamTransport.describe_error(reason)}"
        }
    end
  end

  # The no-downgrade rule. `self: true` skips it: the hub's own
  # newer-than-generation check already ran in apply_to_self_then_fleet/2
  # and abandoned the whole reconcile if it tripped, so re-running it here
  # would just re-derive an answer we already acted on.
  defp check_not_newer(generation, target, opts) do
    if Keyword.get(opts, :self, false) or not newer_than_generation?(target, generation) do
      :ok
    else
      %{
        status: :skipped,
        reason:
          "#{target}'s image was built after generation #{generation.base_sha} was published; " <>
            "reconciling would downgrade it"
      }
    end
  end

  defp newer_than_generation?(target, generation) do
    case BeamTransport.built_at(target) do
      {:ok, built_at} ->
        DateTime.compare(built_at, generation.inserted_at) == :gt

      {:error, reason} ->
        # Absent evidence is not evidence of newness — see the ordering
        # section of the moduledoc for why this errs toward reconciling.
        Logger.debug(
          "CodePush: #{target} did not report a usable built_at (#{inspect(reason)}); " <>
            "treating it as NOT newer than the generation and reconciling it."
        )

        false
    end
  end

  # ------------------------------------------------------------------
  # Publish
  # ------------------------------------------------------------------

  defp do_publish(payload, opts, state) do
    attrs = %{
      base_sha: payload.base_sha,
      dirty: payload.dirty,
      published_by: Keyword.get(opts, :published_by) || payload[:published_by],
      published_from_node: payload[:published_from_node],
      erts_version: payload.erts_version,
      otp_release: payload[:otp_release],
      elixir_version: payload[:elixir_version],
      compiler_version: payload[:compiler_version],
      forced_reasons: payload[:forced_reasons] || [],
      notes: Keyword.get(opts, :notes)
    }

    entries = BeamTransport.sanitize(payload.entries)

    case CodeGenerations.publish(attrs, entries) do
      {:ok, generation} ->
        if payload.dirty do
          Logger.warning(
            "CodePush: published DIRTY generation #{generation.id} from #{generation.base_sha} — " <>
              "the fleet will be running uncommitted code."
          )
        end

        Logger.info(
          "CodePush: published generation #{generation.id} (#{generation.base_sha}, " <>
            "#{generation.module_count} modules, #{generation.total_bytes} bytes)."
        )

        CodeGenerations.prune()

        state = self_apply(generation, state)
        {{:ok, result}, state} = do_reconcile_all([], state)

        {{:ok,
          Map.put(
            result,
            :generation,
            CodeGenerations.summarize(CodeGenerations.get(generation.id))
          )}, state}

      {:error, reason} ->
        {{:error, reason}, state}
    end
  end

  # Modules `target` can still execute that the generation does not contain.
  # Excluded modules are filtered out: OrcaHub.BuildInfo is deliberately in
  # no generation ever, so without this it would be reported as orphaned on
  # every node forever — and would be a candidate for purging, which would
  # take /api/version down with it.
  defp orphaned_modules(generation, target) do
    case BeamTransport.resident_modules(target) do
      {:ok, resident} ->
        wanted =
          generation.id
          |> CodeGenerations.manifest()
          |> Map.keys()
          |> MapSet.new(&String.to_atom/1)

        resident
        |> MapSet.difference(wanted)
        |> Enum.reject(&(&1 in BeamTransport.excluded_modules()))
        |> Enum.sort()

      {:error, _reason} ->
        []
    end
  end

  defp do_purge_orphaned(target) do
    case CodeGenerations.current() do
      # Without a generation there is nothing to be orphaned RELATIVE TO, so
      # every module on the node would qualify. Refusing is the only safe
      # reading of the request.
      nil ->
        {:error, :no_generation}

      generation ->
        results =
          generation
          |> orphaned_modules(target)
          |> Enum.map(fn mod -> {mod, BeamTransport.unload(target, mod)} end)

        {:ok,
         %{
           node: to_string(target),
           purged: for({m, {:ok, :purged}} <- results, do: to_string(m)),
           deleted_not_purged: for({m, {:ok, :deleted_not_purged}} <- results, do: to_string(m)),
           wedged: for({m, {:error, :wedged}} <- results, do: to_string(m)),
           errors:
             for {m, {:error, reason}} <- results, reason != :wedged do
               "#{m}: #{BeamTransport.describe_error(reason)}"
             end
         }}
    end
  end

  defp log_node_result(target, %{status: :in_sync}),
    do: Logger.debug("CodePush: #{target} already in sync.")

  defp log_node_result(target, %{status: :reconciled, pushed: n}),
    do: Logger.info("CodePush: reconciled #{target} — #{n} modules loaded.")

  defp log_node_result(target, %{status: status, reason: reason}),
    do: Logger.warning("CodePush: #{target} #{status} — #{reason}")

  defp log_node_result(target, %{status: :partial, errors: errors}),
    do: Logger.warning("CodePush: #{target} partially reconciled — #{Enum.join(errors, "; ")}")

  defp log_node_result(target, result),
    do: Logger.info("CodePush: #{target} — #{inspect(result)}")
end
