defmodule OrcaHub.EmailInboxSupervisor do
  @moduledoc """
  DynamicSupervisor for `OrcaHub.EmailInbox.Poller` processes — one per
  enabled `email_inboxes` row.

  Hub-only: mailbox polling must never run on an agent node (see
  `OrcaHub.Application`), so this supervisor only appears in `hub_children/1`.
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
