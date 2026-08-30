defmodule OrcaHub.PiConfigSync do
  @moduledoc """
  Materializes hub-managed pi config (`OrcaHub.PiConfig`) into this node's
  `~/.pi/agent/` — custom providers in `models.json`, top-level
  `settings.json` keys, and one file per entry under `extensions/`,
  `prompts/`, and `themes/`.

  pi reads all of these from a hardcoded global dir (`OrcaHub.NodeConfig`'s
  `home_root(:pi, opts)`) with no remote-config support, so the hub DB is
  the source of truth and every node (hub + agent) runs this GenServer to
  keep its own `~/.pi/agent/` in sync — the same architecture as
  `OrcaHub.SkillSync`, whose GenServer plumbing this mirrors: boot sync with
  bounded hub-unreachable retry, `{:pi_config_updated}` broadcasts debounced
  1 second, and a 30-minute periodic fallback sync.

  ## Ownership manifest

  One manifest at `~/.pi/agent/.orca-managed-pi-config.json` (deliberately
  NOT colliding with `SkillSync`'s per-`skills/`-dir `.orca-managed.json`)
  records what this process owns, per surface:

      %{"providers"  => %{provider_key => sha256_of_spec},
        "settings"   => %{settings_key => sha256_of_value},
        "extensions" => %{filename => sha256_of_body},
        "prompts"    => %{filename => sha256_of_body},
        "themes"     => %{filename => sha256_of_body}}

  A manifest-listed name that's no longer in the enabled DB set (disabled or
  deleted) is REMOVED from disk — the provider key is dropped from
  `models.json`, the settings key from `settings.json`, the file unlinked —
  and dropped from the manifest. Anything not in the manifest and not in the
  DB set is node-local and always preserved.

  ## Conflict rule (deliberately unlike SkillSync)

  If a provider key / settings key / file already exists locally with the
  same name as a hub-managed entry but is NOT in the manifest, **the hub
  version wins**: it's overwritten, a warning naming the node and entry is
  logged, and it's adopted into the manifest from then on. `SkillSync` skips
  such collisions forever, which made migrating already-hand-configured
  nodes painful — and hand-configured nodes are precisely the migration path
  here.

  ## Blast radius

  Only the four surfaces above are ever written. `auth.json`,
  `models-store.json`, `sessions/`, `bin/`, and anything dot-prefixed are
  never read or written — enforced by construction (a name can't start with
  `.` or contain a path separator, per `OrcaHub.PiConfig.Entry`'s validation,
  re-checked here) plus the fact that this module only ever touches names it
  already knows about, never a directory listing.

  ## Propagation to running sessions

  pi reads `models.json` when `/model` opens and loads extensions at process
  start, so a session whose warm port is ALREADY open keeps the old config
  until that port cold-reopens. Sync therefore only busts the hub's cached
  `pi --list-models` result for the node (`{:pi_models_changed, node}` on the
  `"pi_config"` topic → `Backend.Cache.invalidate/1` on every node), so the
  model picker reflects new providers promptly. Evicting idle warm pi ports
  node-wide would need something like the per-session `/mcp`-flag rebake path
  (`SessionRunner.consume_pending_rebake/1` → `:evict_warm`), but there's no
  existing node-wide API for it and `WarmPool`'s rows don't carry a backend —
  left for Phase 2 rather than building new eviction machinery here.

  ## Testing

  The whole GenServer loop — not just the boot sync — is gated behind
  `config :orca_hub, :pi_config_sync_enabled` (`false` in `config/test.exs`)
  so a live `{:pi_config_updated}` broadcast during `mix test` can never
  reach this process and write to the dev host's real `~/.pi/agent`. Tests
  call `sync/1` directly with an injected `:home_dir` and an explicit
  `:cli_installed?` override (a test host may or may not have pi installed).
  """

  use GenServer
  require Logger

  alias OrcaHub.{
    Backend,
    HubRPC,
    Mode,
    NodeConfig,
    PiConfig.Entry,
    SessionRunner
  }

  @manifest_filename ".orca-managed-pi-config.json"
  @models_filename "models.json"
  @settings_filename "settings.json"
  @debounce_ms 1_000
  @periodic_interval_ms :timer.minutes(30)
  @boot_delay_ms 2_000
  @boot_retry_delay_ms 15_000
  @max_boot_retries 20

  # manifest section <- kind, for the three file-per-entry kinds
  @dir_surfaces %{
    "extension" => "extensions",
    "prompt" => "prompts",
    "theme" => "themes"
  }

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Whether the GenServer runs its boot-time / periodic / broadcast-driven sync loop."
  def enabled? do
    Application.get_env(:orca_hub, :pi_config_sync_enabled, true)
  end

  @impl true
  def init(_opts) do
    if enabled?() do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, OrcaHub.PiConfig.topic())
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
          "PiConfigSync: giving up on boot sync, hub still unreachable after #{@max_boot_retries} retries"
        )

        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:pi_config_updated}, state) do
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

  # A node whose models.json changed announces it on the same topic; every
  # node drops its own cached `pi --list-models` result FOR THAT NODE, so the
  # session model picker picks up new providers without waiting out the TTL.
  @impl true
  def handle_info({:pi_models_changed, node_name}, state) do
    Backend.Cache.invalidate({:models_for, "pi", node_name})
    {:noreply, state}
  end

  # A node whose pi config changed and needs warm port eviction broadcasts this.
  # Only the TARGET node itself evicts its own idle pi ports - no cross-node RPC.
  @impl true
  def handle_info({:pi_config_warm_port_evict, node_name}, state) do
    # Only act when this node is the target (avoids every node in the cluster
    # simultaneously making RPC calls to the same target for duplicated work).
    if node_name == Node.self() do
      evict_idle_pi_ports()
    end

    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  # -------------------------------------------------------------------
  # Sync (pure-ish — reads/writes disk + HubRPC, no GenServer state) so
  # tests can call it directly without going through the GenServer.
  # -------------------------------------------------------------------

  @doc """
  Runs one sync pass. Options:

    * `:home_dir` — base home override (forwarded to `NodeConfig`).
    * `:cli_installed?` — 1-arity fun deciding whether pi is installed on
      this node (default `NodeConfig.cli_installed?/2`). A node without pi
      is left completely untouched.
    * `:entries` — the enabled entries to materialize (default fetched fresh
      via `HubRPC.list_enabled_pi_config_entries/0`).

  Returns `:ok`. Writes nothing when nothing changed — every surface
  compares decoded content (not bytes) before touching the filesystem, so a
  repeat sync is a true no-op.
  """
  def sync(opts \\ []) do
    installed? = Keyword.get(opts, :cli_installed?, &NodeConfig.cli_installed?(&1, opts))

    if installed?.(:pi) do
      entries =
        opts
        |> Keyword.get_lazy(:entries, fn -> HubRPC.list_enabled_pi_config_entries() end)
        |> Enum.filter(&(Map.get(&1, :enabled, true) and safe_name?(&1)))
        |> Enum.group_by(& &1.kind)

      root = NodeConfig.home_root(:pi, opts)
      manifest_path = Path.join(root, @manifest_filename)
      manifest_existed? = File.regular?(manifest_path)
      manifest = read_manifest(manifest_path)

      # When the hub returns empty entries (all groups empty), preserve existing
      # managed config instead of wiping it. This protects against transient DB
      # issues where the hub temporarily returns empty while entries are actually
      # enabled. If entries exist but are all disabled, the sync will still
      # preserve existing config (conservative approach for availability).
      entries_empty? = Enum.all?(Map.values(entries), & &1 == [])
      preserve_existing? = entries_empty? and manifest_existed?

      # If we would write empty but should preserve, use existing manifest data
      {providers, models_changed?} =
        if preserve_existing? do
          {manifest["providers"], false}
        else
          sync_providers(root, Map.get(entries, "provider", []), manifest["providers"])
        end

      settings =
        if preserve_existing? do
          manifest["settings"]
        else
          sync_settings(root, Map.get(entries, "setting", []), manifest["settings"])
        end

      dirs =
        if preserve_existing? do
          Map.drop(manifest, ["providers", "settings"])
        else
          Map.new(@dir_surfaces, fn {kind, dirname} ->
            section = sync_dir(root, dirname, kind, Map.get(entries, kind, []), manifest[dirname])
            {dirname, section}
          end)
        end

      new_manifest =
        Map.merge(%{"providers" => providers, "settings" => settings}, dirs)

      if new_manifest != manifest or not manifest_existed? do
        write_manifest(manifest_path, new_manifest)
      end

      if models_changed?, do: notify_models_changed()

      # Evict idle pi ports on this node if any providers were added or removed
      if models_changed? do
        notify_warm_port_evict(node())
      end
    end

    :ok
  end

  @doc """
  What THIS node's sync process manages, read straight from the ownership
  manifest — `%{"providers" => [names], "settings" => [keys], "extensions"
  => [filenames], "prompts" => [...], "themes" => [...]}` (empty lists when
  there's no manifest yet). Phase 2's UI badges hub-managed entries in the
  on-disk config browser with this. Like every other `NodeConfig`-adjacent
  call, invoke via `Cluster.rpc/4` so `home_root/2` resolves the TARGET
  node's home directory rather than the caller's.
  """
  def managed_names(opts \\ []) do
    :pi
    |> NodeConfig.home_root(opts)
    |> Path.join(@manifest_filename)
    |> read_manifest()
    |> Map.new(fn {section, entries} -> {section, entries |> Map.keys() |> Enum.sort()} end)
  end

  # ── models.json ──────────────────────────────────────────────────────

  defp sync_providers(root, entries, managed) do
    path = Path.join(root, @models_filename)
    desired = Map.new(entries, &{&1.name, &1.spec})

    {doc, existed?} = read_json_with_backup(path)
    existing = if is_map(doc["providers"]), do: doc["providers"], else: %{}

    Enum.each(Map.keys(desired), fn name ->
      if Map.has_key?(existing, name) and not Map.has_key?(managed, name) do
        warn_adopt("provider #{name}", path)
      end
    end)

    providers =
      existing
      |> drop_stale(managed, desired)
      |> Map.merge(desired)

    new_doc =
      if providers == %{} and not Map.has_key?(doc, "providers"),
        do: doc,
        else: Map.put(doc, "providers", providers)

    changed? = write_json_if_changed(path, doc, new_doc, existed?)

    {Map.new(desired, fn {name, spec} -> {name, sha256(canonical(spec))} end), changed?}
  end

  # ── settings.json ────────────────────────────────────────────────────

  defp sync_settings(root, entries, managed) do
    path = Path.join(root, @settings_filename)
    desired = Map.new(entries, &{&1.name, &1.spec["value"]})

    {doc, existed?} = read_json_with_backup(path)

    Enum.each(Map.keys(desired), fn key ->
      if Map.has_key?(doc, key) and not Map.has_key?(managed, key) do
        warn_adopt("settings key #{key}", path)
      end
    end)

    new_doc =
      doc
      |> drop_stale(managed, desired)
      |> Map.merge(desired)

    write_json_if_changed(path, doc, new_doc, existed?)

    Map.new(desired, fn {key, value} -> {key, sha256(canonical(value))} end)
  end

  # ── extensions/ · prompts/ · themes/ ─────────────────────────────────

  defp sync_dir(root, dirname, kind, entries, managed) do
    dir = Path.join(root, dirname)
    ext = Entry.extension_for(kind)
    desired = Map.new(entries, &{&1.name <> ext, &1.spec["body"] || ""})

    Enum.each(desired, fn {filename, body} ->
      path = Path.join(dir, filename)
      exists? = File.regular?(path)

      if exists? and not Map.has_key?(managed, filename), do: warn_adopt(filename, dir)

      unless exists? and File.read!(path) == body do
        File.mkdir_p!(dir)
        atomic_write!(path, body)
      end
    end)

    managed
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(desired, &1))
    |> Enum.each(&File.rm(Path.join(dir, &1)))

    Map.new(desired, fn {filename, body} -> {filename, sha256(body)} end)
  end

  # ── shared file helpers ──────────────────────────────────────────────

  # Previously-managed keys whose entry is gone (disabled/deleted) are the
  # ONLY keys sync removes — unmanaged node-local keys are always preserved.
  defp drop_stale(map, managed, desired) do
    managed
    |> Map.keys()
    |> Enum.reject(&Map.has_key?(desired, &1))
    |> Enum.reduce(map, &Map.delete(&2, &1))
  end

  # Reads a JSON object. An absent file reads as `{}`. An unparseable one
  # ALSO reads as `{}`, but only after its bytes are preserved once at
  # `<path>.bak` — we're about to overwrite it, and a hand-edited file with
  # a stray comma shouldn't be silently destroyed.
  defp read_json_with_backup(path) do
    case File.read(path) do
      {:error, _} ->
        {%{}, false}

      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, doc} when is_map(doc) ->
            {doc, true}

          _ ->
            backup = path <> ".bak"
            unless File.exists?(backup), do: File.write!(backup, content)

            Logger.warning(
              "PiConfigSync: #{path} on #{node()} is not a JSON object — backed up to #{backup} and rewritten"
            )

            {%{}, true}
        end
    end
  end

  # Writes only on a real content change (decoded-map comparison, so
  # formatting/key-order churn never causes a write). Refuses to CREATE a
  # file that has nothing managed in it. Returns whether it wrote.
  defp write_json_if_changed(path, old_doc, new_doc, existed?) do
    cond do
      new_doc == old_doc -> false
      not existed? and new_doc == %{} -> false
      true -> write_json!(path, new_doc)
    end
  end

  defp write_json!(path, doc) do
    File.mkdir_p!(Path.dirname(path))
    atomic_write!(path, Jason.encode!(doc, pretty: true) <> "\n")
    true
  end

  # tmp + rename in the same directory: pi may read these files at any
  # moment (it re-reads models.json every time /model opens), and a rename
  # is atomic, so it can never observe a half-written file.
  defp atomic_write!(path, content) do
    tmp = path <> ".orca-tmp"
    File.write!(tmp, content)
    File.rename!(tmp, path)
  end

  defp warn_adopt(what, where) do
    Logger.warning(
      "PiConfigSync: #{node()} had an unmanaged #{what} in #{where} — hub version wins, adopting it"
    )
  end

  # Defence in depth over Entry's name validation: an entry whose name could
  # escape its surface (path separator, leading dot) is skipped outright,
  # even if a bad row somehow reached the DB.
  defp safe_name?(%{name: name}) when is_binary(name) do
    name != "" and not String.starts_with?(name, ".") and
      not String.contains?(name, ["/", "\\"]) and name not in [".", ".."]
  end

  defp safe_name?(_), do: false

  defp canonical(value), do: Jason.encode!(value)

  defp sha256(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp read_manifest(manifest_path) do
    sections = ["providers", "settings" | Map.values(@dir_surfaces)]
    empty = Map.new(sections, &{&1, %{}})

    with {:ok, content} <- File.read(manifest_path),
         {:ok, doc} when is_map(doc) <- Jason.decode(content) do
      Map.new(sections, fn section ->
        case doc[section] do
          entries when is_map(entries) -> {section, entries}
          _ -> {section, %{}}
        end
      end)
    else
      _ -> empty
    end
  end

  defp write_manifest(manifest_path, manifest) do
    File.mkdir_p!(Path.dirname(manifest_path))
    atomic_write!(manifest_path, Jason.encode!(manifest, pretty: true) <> "\n")
  end

  # -------------------------------------------------------------------
  # Private (GenServer plumbing)
  # -------------------------------------------------------------------

  defp schedule_periodic, do: Process.send_after(self(), :periodic_sync, @periodic_interval_ms)

  defp do_sync do
    sync()
  rescue
    e -> Logger.warning("PiConfigSync: sync failed: " <> Exception.message(e))
  catch
    kind, reason -> Logger.warning("PiConfigSync: sync crashed: #{inspect({kind, reason})}")
  end

  defp notify_models_changed do
    Phoenix.PubSub.broadcast(
      OrcaHub.PubSub,
      OrcaHub.PiConfig.topic(),
      {:pi_models_changed, node()}
    )
  end

  defp notify_warm_port_evict(node_name) do
    Phoenix.PubSub.broadcast(
      OrcaHub.PubSub,
      OrcaHub.PiConfig.topic(),
      {:pi_config_warm_port_evict, node_name}
    )
  end

  # When called with a node_name (cross-node), this was used before the fix that
  # makes only the target node evict its own ports. Kept as documentation that
  # the old path did cross-node RPC (which has been removed in favor of local
  # eviction). The old implementation had RPC error tolerance; now only local
  # eviction is used (evict_idle_pi_ports/0 below).
  #
  # defp evict_idle_pi_ports(node_name) do
  #   case Cluster.rpc(node_name, Streaming.WarmPool, :warm_rows, []) do
  #     {:error, _} = err ->
  #       Logger.warning("PiConfigSync: evict_idle_pi_ports rpc failed: #{inspect(err)}")
  #       :ok
  #     rows when is_list(rows) ->
  #       rows
  #       |> Enum.filter(fn {_sid, _pid, _ts, _status, backend} -> backend == :pi end)
  #       |> Enum.map(fn {session_id, _pid, _ts, _status, _backend} -> session_id end)
  #       |> Enum.each(&SessionRunner.evict_warm/1)
  #   end
  # end

  # Local eviction: get all warm sessions on this node, filter for pi backend,
  # and call evict_warm on each.
  defp evict_idle_pi_ports do
    case OrcaHub.Streaming.WarmPool.warm_rows() do
      [] ->
        :ok

      rows ->
        sessions_on_node =
          rows
          |> Enum.filter(fn {_sid, _pid, _ts, _status, backend} -> backend == :pi end)
          |> Enum.map(fn {session_id, _pid, _ts, _status, _backend} -> session_id end)

        Enum.each(sessions_on_node, fn session_id ->
          SessionRunner.evict_warm(session_id)
        end)
    end
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
