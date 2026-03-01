import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :orca_hub, OrcaHub.Repo,
  username: System.get_env("DB_USERNAME", "orca_hub"),
  password: System.get_env("DB_PASSWORD", "postgres"),
  hostname: "192.168.1.177",
  database: "orca_hub_dev",
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
