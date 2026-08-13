defmodule OrcaHub.EmailInboxLoader do
  @moduledoc """
  Starts an `OrcaHub.EmailInbox.Poller` for every enabled `email_inboxes` row
  on boot — the inbound-email analogue of `OrcaHub.TriggerLoader`.

  Hub-only. There is no settings UI in v1, so this runs once at boot;
  `OrcaHub.EmailInbox.Poller.start/1` starts one for an inbox created later
  without a restart.
  """

  use GenServer

  require Logger

  alias OrcaHub.EmailInbox.Poller
  alias OrcaHub.EmailInboxes

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    send(self(), :sync)
    {:ok, []}
  end

  @impl true
  def handle_info(:sync, state) do
    sync()
    {:noreply, state}
  end

  @doc "Start a poller for each enabled inbox. Safe to call more than once."
  def sync do
    Enum.each(EmailInboxes.list_enabled_email_inboxes(), fn inbox ->
      case Poller.start(inbox) do
        {:ok, _pid} ->
          Logger.info("Started email poller for inbox #{inbox.name}")

        {:error, {:already_started, _pid}} ->
          :ok

        {:error, reason} ->
          Logger.error("Could not start email poller for inbox #{inbox.name}: #{inspect(reason)}")
      end
    end)
  rescue
    # Boot-time: a DB hiccup here must not take the supervision tree down.
    e ->
      Logger.error("EmailInboxLoader sync failed: #{Exception.message(e)}")
      :error
  end
end
