import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :orca_hub, OrcaHub.Repo,
  username: System.get_env("DB_USERNAME", "orca_hub"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: System.get_env("DB_HOST", "127.0.0.1"),
  database: System.get_env("DB_NAME", "orca_hub_dev"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :orca_hub, OrcaHubWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "EAMLyry8Ez30TVvjzclymvd1zMh6pO7OrOBbRGITNojyZsDW0fzyG5rNoJSAL2xr",
  server: false

# In test we don't send emails
config :orca_hub, OrcaHub.Mailer, adapter: Swoosh.Adapters.Test

# Memory service is disabled by default in test, regardless of what a
# developer's .env sets for dev — tests that need it stub it explicitly via
# Application.put_env(:orca_hub, :memory_service_req_options, plug: {Req.Test, ...}).
config :orca_hub, :memory_service_url, nil
config :orca_hub, :memory_service_token, nil

# Same for the embedding endpoint (OrcaHub.Embeddings) — nil means disabled,
# so the suite never reaches the network. Tests that exercise the HTTP path
# set :embedding_url plus :embedding_req_options (plug: {Req.Test, ...}).
config :orca_hub, :embedding_url, nil
config :orca_hub, :embedding_model, "qwen3-embedding-0.6b"
config :orca_hub, :embedding_dims, 1024

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

# OrcaHub.SkillSync's boot-time/periodic sync writes real files under a
# node's home dir (~/.claude, ~/.codex, ~/.pi/agent) — mix test boots the
# full application against the shared dev DB, so this must stay off here.
# Tests call OrcaHub.SkillSync.sync/1 directly with an injected :home_dir.
config :orca_hub, :skill_sync_enabled, false

# Same hazard for OrcaHub.PiConfigSync, which writes ~/.pi/agent/models.json,
# settings.json, extensions/, prompts/, and themes/. The ENTIRE GenServer loop
# is gated on this (not just the boot sync), so a live {:pi_config_updated}
# broadcast during mix test can't reach it either. Tests call
# OrcaHub.PiConfigSync.sync/1 directly with an injected :home_dir.
config :orca_hub, :pi_config_sync_enabled, false

# OrcaHub.PiModelSync's boot/periodic tick makes a live HTTP call to the
# local LLM gateway and then WRITES the resolved model list back to real
# pi_config_entries rows in the shared dev DB. mix test boots the full
# application, so the loop must stay off here. Tests call
# OrcaHub.PiModelSync.refresh_entry/2 with an injected :fetcher instead.
config :orca_hub, :pi_model_sync_enabled, false

# OrcaHub.MemoryGit.Server's idle-transition hook (invoked from
# SessionRunner, which mix test's SessionRunner/state-machine tests drive
# for real) writes real files under a node's home dir (~/.claude, ~/.codex)
# and would even try to hit Gitea — must stay off here. Tests call
# OrcaHub.MemoryGit.Server.run_pass/2 (or the MemoryGit/MemorySync
# functions directly) with an injected :home_dir instead.
config :orca_hub, :memory_git_enabled, false

# OrcaHub.JobWatcher's poll/kill-grace intervals — fast in test so
# OrcaHub.JobWatcher/JobResumer tests that drive a real detached process to
# completion don't each cost multiple seconds of real wall-clock waiting.
config :orca_hub, job_poll_interval_ms: 100
config :orca_hub, job_kill_grace_ms: 300

# NOT shortened, unlike the two above. `progress_kind: "command"` samples fork a
# real shell, and this is the budget for that fork — so a short suite-wide value
# is a timing threshold every command test has to beat while the whole suite
# competes for the machine. At 200ms it lost: `sample/1 — command, unparseable
# free text` failed twice in a row in a full run (`:unchanged`, i.e. the echo was
# reaped as a timeout) while passing alone every time, on a box where an idle
# `sh -c echo` measures 2-26ms. Tests get production's own margin instead; the
# one test that needs a SHORT bound sets it for itself.
config :orca_hub, job_progress_command_timeout_ms: 5_000

# OrcaHub.Cluster.CodePush's boot reconcile reads the stored code generation
# out of the SHARED DEV DB and hot-loads its beams into whatever node is
# running — which under `mix test` is the test node itself. A generation left
# in the dev DB by real use would therefore swap the code out from under the
# suite mid-run. The entire loop is gated on this (nodeup handling included),
# not just the boot pass. Tests drive CodePush by starting their own instance
# with monitor_nodes: false and calling into it directly.
config :orca_hub, :code_reconcile_enabled, false

# Short health window so circuit-breaker tests don't each pay 30s of real
# wall-clock waiting for a generation to be marked healthy.
config :orca_hub, :code_push_health_window_ms, 150

# THE TEST BYPASS for the publish-provenance guard, and the only place it is
# ever set. Every generation is stamped with the compile-time Mix.env() of
# the code that published it (OrcaHub.CodeGenerations.Provenance); an
# applying node refuses any generation stamped "test", because this database
# is shared with the local systemd PRODUCTION instance and a row escaping the
# test sandbox would otherwise be a live node hot-loading modules that only
# ever existed inside a test.
#
# The feature's own tests legitimately publish AND apply generations, so the
# TEST NODE opts into trusting test provenance here. The switch is read by
# whoever is APPLYING, so it cannot travel with the row: a production
# instance never sets it and refuses that row no matter who wrote it. Tests
# asserting the refusal flip this off for themselves.
config :orca_hub, :trust_test_code_generations, true

# OrcaHub.SessionResumer (and OrcaHub.JobResumer, which shares the flag)
# schedule a :check tick on boot. mix test boots the full application against
# the SHARED DEV DB, and the suite creates hundreds of non-archived
# `status: "running"` sessions via fixtures — indistinguishable, to the
# resumer's query, from real orphans left by a deploy. A tick that lands
# inside an async: false test's shared-sandbox window resumes those fixtures
# for real: it starts runners and WRITES message rows that outlive the
# rollback. That is the flake behind session_heartbeat_job_wake_test's
# "a job still in verifying does not wake anything" failures.
#
# Both resumers' logic is driven directly by their tests
# (SessionResumer.resume_session/1, JobResumer.resume_jobs/0), so nothing
# depends on the ambient timer.
config :orca_hub, :auto_resume, false
