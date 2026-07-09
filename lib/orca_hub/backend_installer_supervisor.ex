defmodule OrcaHub.BackendInstallerSupervisor do
  @moduledoc """
  DynamicSupervisor for `OrcaHub.BackendInstaller.Job` processes — at most
  one per backend on THIS node (enforced via `OrcaHub.BackendInstallerRegistry`,
  a unique-keys registry). Runs on every node (hub and agent), mirroring
  `OrcaHub.LoginSupervisor`.
  """

  use DynamicSupervisor

  def start_link(_opts) do
    DynamicSupervisor.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
