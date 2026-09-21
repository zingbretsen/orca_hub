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
         {:ok, entries} <- BeamTransport.load_beams(ebin) do
      {:ok,
       %{
         entries: BeamTransport.sanitize(entries),
         base_sha: base_sha,
         dirty: dirty?,
         erts_version: List.to_string(:erlang.system_info(:version)),
         otp_release: List.to_string(:erlang.system_info(:otp_release)),
         elixir_version: System.version(),
         published_from_node: to_string(node()),
         forced_reasons: forced_reasons(verdict),
         ebin: ebin
       }}
    end
  end

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
          push_needed(generation, target, needed, report)

        {:error, reason} ->
          %{status: :error, reason: "drift check failed: #{inspect(reason)}"}
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
        %{status: :error, reason: "push failed: #{inspect(reason)}"}
    end
  end

  defp check_erts(generation, target) do
    expected = generation.erts_version

    case BeamTransport.erts_version(target) do
      {:ok, ^expected} ->
        :ok

      {:ok, remote} ->
        %{
          status: :skipped,
          reason:
            "ERTS mismatch: generation was compiled on #{generation.erts_version}, " <>
              "#{target} runs #{remote}"
        }

      {:error, reason} ->
        %{status: :error, reason: "could not read ERTS version: #{inspect(reason)}"}
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
