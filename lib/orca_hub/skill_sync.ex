defmodule OrcaHub.SkillSync do
  @moduledoc """
  Materializes hub-managed global skills (`OrcaHub.Skills`) onto this
  node's disk, one `SKILL.md` per enabled+targeted skill per installed
  backend CLI (`OrcaHub.NodeConfig.backends/0`).

  No agent CLI supports remote/custom skill paths — Claude Code, Codex,
  and pi all read only from a hardcoded `<home_root>/skills/<name>/SKILL.md`
  — so the hub DB (`skills` table) is the source of truth and every node
  (hub + agent) runs this GenServer to keep its own local skill dirs in
  sync with it.

  Runs on EVERY node. On init it subscribes to the `"skills"` PubSub topic
  and schedules a boot sync. Agent nodes may not have hub connectivity yet
  at boot, so the boot sync retries with backoff (bounded), same pattern as
  `OrcaHub.SessionResumer`. After boot, syncs are triggered by:

    * `{:skills_updated}` broadcasts (`OrcaHub.Skills` broadcasts this on
      every create/update/delete) — debounced briefly so a burst of changes
      only triggers one sync.
    * A periodic fallback sync every 30 minutes, in case a broadcast is
      ever missed (e.g. a node reconnecting after a network blip).

  ## Ownership manifest

  Each backend's `skills/` root gets a `.orca-managed.json` file recording
  which skill directories THIS sync process owns (`%{"skills" => %{name =>
  sha256_of_written_SKILL.md}}`). Sync only ever touches manifest-listed
  dirs:

    * A DB skill whose target dir already exists but ISN'T in the manifest
      is a node-local, hand-made skill — sync skips it and logs a warning
      rather than clobbering it.
    * A manifest-listed dir no longer in the enabled+targeted DB set (skill
      disabled, deleted, or un-targeted for that backend) gets deleted and
      dropped from the manifest.
    * Dot-prefixed dirs (e.g. Codex's vendor `skills/.system/`) are never
      touched — enforced by construction, since a skill name can never
      start with `.` (schema validation) and this module never lists a
      backend's `skills/` dir contents, only reads/writes the specific
      names it already knows about.

  ## Testing

  Boot-time sync is gated behind `config :orca_hub, :skill_sync_enabled`
  (`false` in `config/test.exs`) so `mix test` — which boots the full
  application against the shared dev DB — never writes to the dev host's
  real `~/.claude`, `~/.codex`, or `~/.pi/agent`. Tests call `sync/1`
  directly with an injected `:home_dir` (see `OrcaHub.NodeConfig` for the
  same override convention) and, since a test host's installed CLIs vary,
  an explicit `:backends` list and/or `:cli_installed?` override so
  materialization doesn't depend on what happens to be installed on the
  machine running the test.
  """

  use GenServer
  require Logger

  alias OrcaHub.{HubRPC, Mode, NodeConfig}

  @manifest_filename ".orca-managed.json"
  @debounce_ms 1_000
  @periodic_interval_ms :timer.minutes(30)
  @boot_delay_ms 2_000
  @boot_retry_delay_ms 15_000
  @max_boot_retries 20

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Whether the GenServer runs its boot-time / periodic / broadcast-driven sync loop."
  def enabled? do
    Application.get_env(:orca_hub, :skill_sync_enabled, true)
  end

  @impl true
  def init(_opts) do
    # Gated entirely (not just the boot sync itself) behind :skill_sync_enabled
    # — `false` in config/test.exs — so a live `{:skills_updated}` broadcast
    # during `mix test` can never reach this process and write to the test
    # host's real home dirs. Tests call `sync/1` directly instead.
    if enabled?() do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "skills")
      schedule_periodic()
      Process.send_after(self(), :boot_sync, @boot_delay_ms)
    end

    {:ok, %{boot_retries: 0, debounce_timer: nil}}
  end

  @impl true
  def handle_info(:boot_sync, state) do
    cond do
      hub_reachable?() ->
        do_sync()
        {:noreply, state}

      state.boot_retries < @max_boot_retries ->
        Process.send_after(self(), :boot_sync, @boot_retry_delay_ms)
        {:noreply, %{state | boot_retries: state.boot_retries + 1}}

      true ->
        Logger.warning(
          "SkillSync: giving up on boot sync, hub still unreachable after #{@max_boot_retries} retries"
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:skills_updated}, state) do
    if state.debounce_timer, do: Process.cancel_timer(state.debounce_timer)
    timer = Process.send_after(self(), :debounced_sync, @debounce_ms)
    {:noreply, %{state | debounce_timer: timer}}
  end

  @impl true
  def handle_info(:debounced_sync, state) do
    do_sync()
    {:noreply, %{state | debounce_timer: nil}}
  end

  @impl true
  def handle_info(:periodic_sync, state) do
    schedule_periodic()
    do_sync()
    {:noreply, state}
  end

  # -------------------------------------------------------------------
  # Sync (pure-ish — reads/writes disk + HubRPC, no GenServer state) so
  # tests can call it directly without going through the GenServer.
  # -------------------------------------------------------------------

  @doc """
  Runs one sync pass. Options:

    * `:home_dir` — base home override (forwarded to `NodeConfig`).
    * `:backends` — which backend atoms to attempt (default
      `NodeConfig.backends/0`).
    * `:cli_installed?` — 1-arity fun deciding whether a backend is
      "installed" on this node (default `NodeConfig.cli_installed?/2`).
    * `:skills` — the enabled skills to materialize (default fetched fresh
      via `HubRPC.list_enabled_skills/0`).
  """
  def sync(opts \\ []) do
    backends = Keyword.get(opts, :backends, NodeConfig.backends())
    installed? = Keyword.get(opts, :cli_installed?, &NodeConfig.cli_installed?(&1, opts))
    skills = Keyword.get_lazy(opts, :skills, fn -> HubRPC.list_enabled_skills() end)

    backends
    |> Enum.filter(installed?)
    |> Enum.each(&sync_backend(&1, skills, opts))

    :ok
  end

  @doc """
  Names of skills THIS node's sync process manages for `backend` — read
  straight from that backend's `skills/.orca-managed.json` ownership
  manifest (empty `MapSet` if the manifest doesn't exist yet). Used by
  `NodeLive.Show` to badge/read-only-lock hub-managed skill directories in
  the on-disk config browser, so a hand-edit there doesn't get silently
  clobbered by the next sync. Like every other `NodeConfig`-adjacent call,
  invoke via `Cluster.rpc/4` so `home_root/2` resolves the TARGET node's
  home directory rather than the caller's.
  """
  def managed_skill_names(backend, opts \\ []) do
    skills_root = Path.join(NodeConfig.home_root(backend, opts), "skills")
    manifest_path = Path.join(skills_root, @manifest_filename)
    manifest_path |> read_manifest() |> Map.keys() |> MapSet.new()
  end

  defp sync_backend(backend, skills, opts) do
    backend_str = Atom.to_string(backend)
    skills_root = Path.join(NodeConfig.home_root(backend, opts), "skills")
    manifest_path = Path.join(skills_root, @manifest_filename)
    manifest_existed? = File.regular?(manifest_path)
    managed = read_manifest(manifest_path)

    targeted = Enum.filter(skills, &(&1.enabled and backend_str in &1.backends))
    targeted_names = MapSet.new(targeted, & &1.name)

    after_writes =
      Enum.reduce(targeted, managed, fn skill, acc ->
        write_skill(skills_root, skill, managed, acc, backend_str)
      end)

    final =
      after_writes
      |> Enum.reject(fn {name, _hash} -> name in targeted_names end)
      |> Enum.reduce(after_writes, fn {name, _hash}, acc ->
        File.rm_rf!(Path.join(skills_root, name))
        Map.delete(acc, name)
      end)

    if final != %{} or manifest_existed? do
      write_manifest(manifest_path, final)
    end
  end

  defp write_skill(skills_root, skill, managed, acc, backend_str) do
    dir = Path.join(skills_root, skill.name)

    if File.dir?(dir) and not Map.has_key?(managed, skill.name) do
      Logger.warning(
        "SkillSync: skipping #{backend_str}/#{skill.name} — unmanaged directory already exists at #{dir}"
      )

      acc
    else
      content = render_skill_md(skill)
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "SKILL.md"), content)
      Map.put(acc, skill.name, sha256(content))
    end
  end

  defp render_skill_md(skill) do
    "---\n" <>
      "name: #{yaml_quote(skill.name)}\n" <>
      "description: #{yaml_quote(skill.description || "")}\n" <>
      "---\n\n" <>
      (skill.body || "")
  end

  # Double-quoted YAML scalar — safe for any description text (colons,
  # quotes, backslashes, newlines included).
  defp yaml_quote(str) do
    escaped =
      str
      |> to_string()
      |> String.replace("\\", "\\\\")
      |> String.replace("\"", "\\\"")
      |> String.replace("\n", "\\n")
      |> String.replace("\t", "\\t")

    "\"#{escaped}\""
  end

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp read_manifest(manifest_path) do
    with {:ok, content} <- File.read(manifest_path),
         {:ok, %{"skills" => skills}} when is_map(skills) <- Jason.decode(content) do
      skills
    else
      _ -> %{}
    end
  end

  defp write_manifest(manifest_path, entries) do
    File.mkdir_p!(Path.dirname(manifest_path))
    File.write!(manifest_path, Jason.encode!(%{"skills" => entries}, pretty: true))
  end

  # -------------------------------------------------------------------
  # Private (GenServer plumbing)
  # -------------------------------------------------------------------

  defp schedule_periodic, do: Process.send_after(self(), :periodic_sync, @periodic_interval_ms)

  defp do_sync do
    sync()
  rescue
    e -> Logger.warning("SkillSync: sync failed: " <> Exception.message(e))
  catch
    kind, reason -> Logger.warning("SkillSync: sync crashed: #{inspect({kind, reason})}")
  end

  defp hub_reachable? do
    if Mode.hub?() do
      true
    else
      Enum.any?(Node.list(), fn n ->
        try do
          :erpc.call(n, Mode, :hub?, [], 5_000)
        catch
          _, _ -> false
        end
      end)
    end
  end
end
