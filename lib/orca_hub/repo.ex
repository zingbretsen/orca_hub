defmodule OrcaHub.Repo do
  use Ecto.Repo,
    otp_app: :orca_hub,
    adapter: Ecto.Adapters.Postgres
end
