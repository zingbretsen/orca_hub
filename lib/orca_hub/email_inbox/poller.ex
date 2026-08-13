defmodule OrcaHub.EmailInbox.Poller do
  @moduledoc """
  One GenServer per enabled `email_inboxes` row: polls the mailbox over IMAP
  and hands each new message to `OrcaHub.EmailInbox.Ingest`.

  Hub-only. Agent nodes never poll mailboxes — see `OrcaHub.Application`.

  ## Poll cycle

  Connect, `SELECT` the folder, reconcile the UIDVALIDITY generation, then
  for each UID above the watermark, in ascending order:

  1. fetch it with `BODY.PEEK[]` (no implicit `\\Seen`),
  2. **commit** — persist `last_uid = uid` and set `\\Seen` on the server,
  3. only then run the accept/reject pipeline for it.

  That ordering is load-bearing, not incidental. Committing before firing
  means a crash between the two AT WORST silently drops one in-flight
  message; committing after firing would mean a crash after a session was
  created re-fires the same trigger on the next poll and creates a duplicate
  session. Dropping a message is recoverable by a human; a duplicate agent
  session acting on someone's email is not.

  A first-ever poll — or one where the server's UIDVALIDITY no longer matches
  the stored one, meaning the mailbox's UIDs have been renumbered and the
  watermark is meaningless — baselines the watermark to the CURRENT highest
  UID. A new inbox starts watching from now; it never replays the mailbox's
  entire history into a fresh agent session.

  The whole cycle is wrapped so no IMAP-side failure (auth rejection,
  timeout, malformed response, hostile message) can crash or restart the
  process — it logs and tries again on the next tick.

  ## Recommended containment for an email-triggered project

  The sender allow-list authenticates WHO sent the message; it says nothing
  about the content. Forwarding other people's mail is the point of this
  feature, so an email-ingested session is, by design, reading text written
  by someone who was never authenticated — text that may be written to look
  like instructions. `TriggerExecutor`'s prompt delimits it as untrusted
  data, but prompt delimiting is a mitigation, not a boundary.

  So give an email trigger a project that can't lose anything:

    * a DEDICATED project pointed at a scratch working directory — not a real
      codebase, not a checkout with credentials or deploy access in it;
    * routed to a node whose `nodes` row has `isolated: true`, so the session
      can't message, inspect, or spawn sessions on any other node
      (`OrcaHub.NodePolicy`);
    * and `scrub_session_env: true` on that node, so the session is spawned
      with an allow-listed environment rather than inheriting the node's
      (`OrcaHub.ClusterNodes.ClusterNode`, `.context/clustering.md`).

  With those three in place, the worst a hostile email body can talk the
  agent into is confined to a throwaway directory on an isolated node.
  """

  use GenServer

  require Logger

  alias OrcaHub.EmailInbox.{ImapClient, Ingest}
  alias OrcaHub.{EmailInboxes, Triggers}

  @default_interval_ms 60_000

  def start_link(inbox), do: GenServer.start_link(__MODULE__, inbox, name: via(inbox.id))

  @doc "Start (or find) a poller for `inbox` under OrcaHub.EmailInboxSupervisor."
  def start(inbox) do
    DynamicSupervisor.start_child(OrcaHub.EmailInboxSupervisor, {__MODULE__, inbox})
  end

  @doc "Poll `inbox_id` right now, synchronously. Test/`iex` seam."
  def poll_now(inbox_id, timeout \\ 60_000) do
    GenServer.call(via(inbox_id), :poll_now, timeout)
  end

  defp via(inbox_id), do: {:via, Registry, {OrcaHub.EmailInboxRegistry, inbox_id}}

  @impl true
  def init(inbox) do
    schedule_poll()
    {:ok, %{inbox_id: inbox.id, name: inbox.name}}
  end

  @impl true
  def handle_info(:poll, state) do
    poll(state)
    schedule_poll()
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def handle_call(:poll_now, _from, state), do: {:reply, poll(state), state}

  defp schedule_poll, do: Process.send_after(self(), :poll, interval_ms())

  @doc "Poll interval in ms (ORCA_EMAIL_POLL_INTERVAL_MS)."
  def interval_ms do
    Application.get_env(:orca_hub, :email_poll_interval_ms, @default_interval_ms)
  end

  # Every failure mode below is contained here: a disabled/deleted inbox, a
  # refused login, a dead connection, a hostile message. The process keeps
  # its timer either way.
  defp poll(state) do
    case EmailInboxes.get_email_inbox(state.inbox_id) do
      nil ->
        Logger.debug("Email poller #{state.name}: inbox row is gone, skipping cycle")
        :ok

      %{enabled: false} ->
        Logger.debug("Email poller #{state.name}: inbox is disabled, skipping cycle")
        :ok

      inbox ->
        run_cycle(inbox)
    end
  rescue
    e ->
      Logger.error("Email poller #{state.name} cycle failed: #{Exception.message(e)}")
      :error
  catch
    kind, reason ->
      Logger.error("Email poller #{state.name} cycle failed: #{inspect({kind, reason})}")
      :error
  end

  defp run_cycle(inbox) do
    result =
      ImapClient.with_connection(inbox, fn client ->
        with {:ok, client, mailbox} <- ImapClient.select(client, inbox.folder),
             {:ok, client, inbox} <- reconcile_uid_validity(client, inbox, mailbox),
             {:ok, client, uids} <- ImapClient.uid_search_after(client, inbox.last_uid) do
          process_uids(client, inbox, uids)
        end
      end)

    case result do
      {:ok, count} ->
        if count > 0, do: Logger.info("Email poller #{inbox.name}: examined #{count} message(s)")
        :ok

      {:error, reason} ->
        Logger.warning("Email poller #{inbox.name}: poll failed — #{inspect(reason)}")
        :error
    end
  end

  # A stored uid_validity that still matches means the watermark is valid. A
  # first-ever poll (nil) or a mismatch (server renumbered the mailbox) means
  # it is not — baseline to the current highest UID and start from now.
  defp reconcile_uid_validity(client, inbox, %{uid_validity: uid_validity}) do
    if not is_nil(uid_validity) and inbox.uid_validity == uid_validity do
      {:ok, client, inbox}
    else
      with {:ok, client, highest} <- ImapClient.highest_uid(client) do
        if is_nil(inbox.uid_validity) do
          Logger.info(
            "Email poller #{inbox.name}: first poll, watching from UID #{highest} onward"
          )
        else
          Logger.warning(
            "Email poller #{inbox.name}: UIDVALIDITY changed " <>
              "(#{inbox.uid_validity} -> #{inspect(uid_validity)}); mailbox was renumbered, " <>
              "re-baselining the watermark to UID #{highest}"
          )
        end

        case EmailInboxes.update_watermark(inbox, %{
               last_uid: highest,
               uid_validity: uid_validity
             }) do
          {:ok, inbox} -> {:ok, client, inbox}
          {:error, changeset} -> {:error, {:watermark_update_failed, changeset}}
        end
      end
    end
  end

  defp process_uids(client, inbox, uids) do
    triggers = Triggers.list_enabled_email_triggers_for_inbox(inbox.id)

    Enum.reduce_while(uids, {:ok, client, 0}, fn uid, {:ok, client, count} ->
      case ImapClient.uid_fetch_raw(client, uid) do
        {:ok, client, raw} ->
          # COMMIT FIRST — see the moduledoc. Everything after this point may
          # crash without ever re-firing this message.
          case commit(client, inbox, uid) do
            {:ok, client, inbox} ->
              Ingest.ingest(inbox, raw, triggers)
              {:cont, {:ok, client, count + 1}}

            {:error, reason} ->
              # Not advancing the watermark would replay this message on the
              # next cycle, so stop here rather than walking further uids.
              {:halt, {:error, reason}}
          end

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp commit(client, inbox, uid) do
    case EmailInboxes.update_watermark(inbox, %{last_uid: uid}) do
      {:ok, inbox} ->
        # Advisory only: \Seen is for the human looking at the mailbox — the
        # DB watermark is the real ledger, so a failure here is not fatal.
        case ImapClient.uid_mark_seen(client, uid) do
          {:ok, client, :ok} ->
            {:ok, client, inbox}

          {:error, reason} ->
            Logger.warning(
              "Email poller #{inbox.name}: could not flag UID #{uid} as seen — #{inspect(reason)}"
            )

            {:ok, client, inbox}
        end

      {:error, changeset} ->
        {:error, {:watermark_update_failed, changeset}}
    end
  end
end
