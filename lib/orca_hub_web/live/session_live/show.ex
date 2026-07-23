defmodule OrcaHubWeb.SessionLive.Show do
  use OrcaHubWeb, :live_view
  require Logger

  alias OrcaHub.{AskUserQuestion, Backend, Cluster, HubRPC, Projects, Sessions}
  alias OrcaHubWeb.{ArtifactSend, Markdown, MessageComponents, TreeComponents}
  alias OrcaHubWeb.SessionLive.{MarkdownBlocks, PlanMode, Todos}

  import OrcaHubWeb.AskUserQuestionComponent

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    {session_node, session} = find_session!(id)

    ensure_runner_started(session_node, id, session)

    # Check if session is remote based on original runner_node (not the fallback)
    remote? = session.runner_node != nil && session.runner_node != Atom.to_string(node())

    maybe_subscribe(socket, id, remote?)

    runner_state = load_runner_state(session_node, id, session)

    {prev_session_id, next_session_id} = HubRPC.get_adjacent_session_ids(session)

    # Display the original node name even if disconnected/unassigned
    session_node_name =
      if session.runner_node, do: Cluster.node_name(session.runner_node), else: "unassigned"

    node_unavailable = node_unavailable_reason(session_node)

    {:ok,
     socket
     |> assign(:session, session)
     # Resolved once from session.backend (never nil/raises — legacy rows
     # default to Claude's capabilities, spec §7). Templates branch on these
     # fields, never on the backend name string.
     |> assign(:capabilities, Backend.capabilities_for(session))
     |> assign(:session_node, session_node)
     |> assign(:session_node_name, session_node_name)
     |> assign(:remote_session, remote?)
     |> assign(:node_unavailable, node_unavailable)
     |> assign(
       :node_unavailable_message,
       node_unavailable && Cluster.node_unavailable_message(node_unavailable)
     )
     |> assign(:cluster_nodes, Cluster.node_info())
     |> assign(:status, runner_state.status)
     |> assign(:messages, runner_state.messages)
     # spec §12.6 — latest pending steer/follow-up queue (pi only; stays
     # empty and unused for backends without `capabilities.steering`).
     # Transient live state, not persisted — refreshed by the runner's
     # {:queue_update, ...} broadcast (SessionRunner's "queue_update"
     # system-event clause), never carried in @messages.
     |> assign(:pi_queue, %{steering: [], follow_up: []})
     |> assign(
       :page_title,
       session.title || (session.project && session.project.name) || session.directory
     )
     |> assign(:prev_session_id, prev_session_id)
     |> assign(:next_session_id, next_session_id)
     |> assign(:tts_autoplay, false)
     |> assign(:open_files, [])
     |> assign(:active_file_tab, nil)
     |> assign(:subscribed_artifact_ids, MapSet.new())
     |> assign(:file_editing, false)
     |> assign(:file_edit_mode, false)
     |> assign(:editing_block, nil)
     |> assign(:block_edit_content, nil)
     |> assign(:show_file_browser, false)
     |> assign(:file_mtimes, %{})
     |> assign(:scroll_to_line, nil)
     |> assign(:scroll_to_block, nil)
     |> assign(:editing_title, false)
     # Claude: model-initiated EnterPlanMode/ExitPlanMode tool_use pair
     # (PlanMode.detect/1). pi: user-toggled `/plan` (spec §12.4) — there is
     # no tool_use to detect, so `pi_plan_mode_from_messages/1` reconstructs
     # from the last `pi_plan_mode` broadcast instead. `||` is safe: a
     # backend only ever produces events one of the two detectors reacts to
     # (Claude never emits `pi_plan_mode`; pi never emits EnterPlanMode), so
     # exactly one side is non-`false` per session.
     |> assign(
       :plan_mode,
       PlanMode.detect(runner_state.messages) || pi_plan_mode_from_messages(runner_state.messages)
     )
     |> assign(:pending_plan_file, nil)
     |> assign(:plan_file_path, nil)
     |> assign(:plan_file_original_mtime, nil)
     |> assign(:todos, [])
     |> assign(:show_todos, false)
     |> assign(:show_commits, false)
     |> assign(:commits, [])
     |> assign(:expanded_commit, nil)
     |> assign(:commit_detail, nil)
     |> assign(:show_artifacts, false)
     |> assign(:session_artifacts, HubRPC.list_artifacts_for_session(id))
     |> assign(:artifact_send_throttle, %{})
     |> assign(:show_terminal, false)
     |> assign(:open_terminals, [])
     |> assign(:active_terminal_id, nil)
     |> assign(:show_mcp_modal, false)
     |> assign(:session_mcp_servers, HubRPC.list_servers_for_session(id))
     |> assign(:all_upstream_servers, HubRPC.list_upstream_servers())
     |> assign(:show_mcp_server_picker, false)
     |> assign(:show_heartbeat_modal, false)
     |> assign(:heartbeat_info, HubRPC.get_heartbeat(id))
     |> assign_ask_user_question(runner_state.status, runner_state.messages)
     # pi's extension-UI reply loop (spec §12.3): reconstructed purely from
     # message history (a "pi_ui_request" with no later matching
     # "pi_ui_response") rather than tracked as separate runner state, so a
     # page reload — even against a dead runner falling back to
     # HubRPC.list_messages/1 below — still shows the pending card. Kept
     # independent of the AskUserQuestion wizard's status/aq_open dance:
     # pi's dialog blocks the port directly, so the session status stays
     # "running" the whole time (no "waiting" transition to key off).
     |> assign(:pending_ui_request, pending_ui_request_from_messages(runner_state.messages))
     # spec §12.8 — header context-window meter (pi only, capability-gated on
     # @capabilities.session_stats). Reconstructed from the last
     # `pi_session_stats` event in history, mirroring @plan_mode's
     # reconstruction; nil (hidden) until the first stats event ever arrives.
     |> assign(:context_percent, context_percent_from_messages(runner_state.messages))
     # Conversation/Tree toggle (view param persisted via handle_params) —
     # tree_* assigns only get populated by load_tree_data/1 once @view is
     # :tree; tree_compose is the per-node "message this session" modal,
     # opened from a tree node regardless of which view loaded it.
     |> assign(:view, :conversation)
     |> assign(:tree_subagents, %{})
     |> assign(:tree_has_subagents, %{})
     |> assign(:tree_compose, nil)
     |> assign(:sessions_topic_subscribed, false)
     |> load_session_todos()
     |> load_session_commits()
     |> allow_upload(:image,
       accept: ~w(.jpg .jpeg .png .gif .webp),
       max_entries: 5,
       max_file_size: 20_000_000,
       auto_upload: true
     )
     |> allow_upload(:file,
       accept: :any,
       max_entries: 5,
       max_file_size: 50_000_000,
       auto_upload: true
     )}
  end

  @impl true
  def handle_params(params, _url, socket) do
    view = if params["view"] == "tree", do: :tree, else: :conversation
    socket = assign(socket, :view, view)

    socket =
      if view == :tree do
        socket |> maybe_subscribe_sessions_topic() |> load_tree_data()
      else
        socket
      end

    {:noreply, socket}
  end

  defp maybe_subscribe_sessions_topic(socket) do
    if connected?(socket) and not socket.assigns.sessions_topic_subscribed do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "sessions")
      assign(socket, :sessions_topic_subscribed, true)
    else
      socket
    end
  end

  # Tree view data: the tree containing this session (root ancestor + every
  # descendant, archived included — see Sessions.get_session_tree/1 doc),
  # plus the cross-session message-edge overlay for that same membership.
  defp load_tree_data(socket) do
    {root, members} = HubRPC.get_session_tree(socket.assigns.session.id)
    session_ids = Enum.map(members, & &1.id)
    sessions_by_id = Map.new(members, &{&1.id, &1})

    interactions = HubRPC.list_session_interactions_for_sessions(session_ids)

    socket
    |> assign(:tree_root, root)
    |> assign(:tree_children_by_parent, TreeComponents.group_children_by_parent(members))
    |> assign(:tree_edges_by_session, TreeComponents.build_edges(interactions, sessions_by_id))
    |> assign(:tree_has_subagents, HubRPC.session_ids_with_subagents(session_ids))
  end

  # -- mount helpers --

  # No-op (never starts a local runner in place of the assigned one) when the
  # session's node is nil/unassigned or currently unreachable — this is the
  # guard against the incident where a debian-owned session got silently
  # adopted and started on the hub during the debian agent's restart window.
  defp ensure_runner_started(session_node, id, session) do
    if session_node && Cluster.node_available?(session_node) do
      unless Cluster.session_alive?(session_node, id) do
        case Cluster.start_session(session_node, id, session) do
          {:ok, _} ->
            :ok

          {:error, reason} ->
            Logger.error("Failed to start session runner for #{id}: #{inspect(reason)}")
        end
      end
    else
      Logger.warning(
        "Skipping runner auto-start for session #{id}: node #{inspect(session_node)} unavailable"
      )
    end
  end

  defp node_unavailable_reason(nil), do: :node_unassigned

  defp node_unavailable_reason(n) do
    unless Cluster.node_available?(n), do: {:node_unavailable, n}
  end

  defp maybe_subscribe(socket, id, remote?) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "session:#{id}")
      # Presence mark for the abandoned-session cleanup (see terminate/2):
      # auto-removed when this LiveView process dies.
      Registry.register(OrcaHub.SessionViewersRegistry, id, %{})
      unless remote?, do: Process.send_after(self(), :poll_file_changes, 2000)
    end
  end

  defp load_runner_state(session_node, id, session) do
    if Cluster.session_alive?(session_node, id) do
      Cluster.get_state(session_node, id)
    else
      saved_messages =
        id
        |> HubRPC.list_messages()
        |> Enum.map(fn msg -> Map.put(msg.data, "timestamp", msg.inserted_at) end)

      %{status: session.status || "error", messages: saved_messages}
    end
  end

  # Derive the pending AskUserQuestion from history and open the modal when the
  # session is waiting on the user. Resets wizard page/selection state.
  #
  # Capability-gated (spec §7/§6.3(5)): backends without `AskUserQuestion`
  # (Codex) never emit that tool name, so `pending` is naturally always nil
  # for them — but the modal-open flag is gated explicitly too, so the
  # interactive wizard can never initiate off a foreign tool name.
  defp assign_ask_user_question(socket, status, messages) do
    pending = AskUserQuestion.pending_questions(messages)
    aq_capable? = socket.assigns.capabilities.ask_user_question

    socket
    |> assign(:pending_questions, pending)
    |> assign(:aq_open, aq_capable? && status == :waiting && pending != nil)
    |> assign(:aq_page, 0)
    |> assign(:aq_selections, %{})
  end

  # Refresh just the pending questions (keep wizard page/selection state).
  defp refresh_pending_questions(socket) do
    assign(socket, :pending_questions, AskUserQuestion.pending_questions(socket.assigns.messages))
  end

  # Open the modal (resetting the wizard) when the session is waiting and a
  # question is present; close it once the session is no longer waiting. The
  # runner broadcasts :waiting before the tool_use event, so we re-check on both
  # status and event updates.
  defp sync_question_modal(socket) do
    %{status: status, pending_questions: pending, aq_open: open?, capabilities: caps} =
      socket.assigns

    cond do
      caps.ask_user_question && status == :waiting && pending && !open? ->
        socket
        |> assign(:aq_open, true)
        |> assign(:aq_page, 0)
        |> assign(:aq_selections, %{})

      status != :waiting && open? ->
        assign(socket, :aq_open, false)

      true ->
        socket
    end
  end

  defp pending_question_list(socket) do
    case socket.assigns.pending_questions do
      %{questions: questions} -> questions
      _ -> []
    end
  end

  # -- pi extension-UI dialog helpers (spec §12.3) --

  defp piui_payload("confirm", value), do: %{"confirmed" => value in ["true", "Yes", "yes"]}
  defp piui_payload(_select_or_input, value), do: %{"value" => value}

  defp handle_pi_ui_events(socket, %{"type" => "pi_ui_request"} = event),
    do: assign(socket, :pending_ui_request, event)

  defp handle_pi_ui_events(socket, %{"type" => "pi_ui_response"}),
    do: assign(socket, :pending_ui_request, nil)

  defp handle_pi_ui_events(socket, _event), do: socket

  # Reconstructs the pending pi extension-UI dialog (if any) from message
  # history: the most recent "pi_ui_request" whose id has no later matching
  # "pi_ui_response". Used at mount so a page reload — including against a
  # dead runner, whose fallback message source is HubRPC.list_messages/1 —
  # still shows the card.
  defp pending_ui_request_from_messages(messages) do
    responded_ids =
      messages
      |> Enum.filter(&(&1["type"] == "pi_ui_response"))
      |> Enum.map(& &1["id"])
      |> MapSet.new()

    messages
    |> Enum.reverse()
    |> Enum.find(fn
      %{"type" => "pi_ui_request", "id" => id} -> not MapSet.member?(responded_ids, id)
      _ -> false
    end)
  end

  # -- pi plan-mode helpers (spec §12.4) --

  # Reconstructs pi's user-toggled plan-mode state from the most recent
  # `pi_plan_mode` broadcast (see Backend.Pi.handle_peer_request/2's
  # "orca-plan-mode" setStatus clause) — mirrors PlanMode.detect/1's role for
  # Claude, but off a different wire signal since pi has no
  # EnterPlanMode/ExitPlanMode tool_use to scan for. Maps straight to
  # `:planning` (no distinct "review" phase for pi — the post-plan "what
  # next?" moment is handled by the extension-UI dialog, not a persisted
  # review state) or `false`.
  defp pi_plan_mode_from_messages(messages) do
    last_event = messages |> Enum.reverse() |> Enum.find(&(&1["type"] == "pi_plan_mode"))

    case last_event do
      %{"enabled" => true} -> :planning
      _ -> false
    end
  end

  defp handle_pi_plan_events(socket, %{"type" => "pi_plan_mode", "enabled" => enabled}) do
    assign(socket, :plan_mode, if(enabled, do: :planning, else: false))
  end

  defp handle_pi_plan_events(socket, _event), do: socket

  # -- pi context meter helpers (spec §12.8) --

  # Reconstructs the LATEST context-window percent from the most recent
  # `pi_session_stats` event (Backend.Pi.normalize/2, spec §12.3) — mirrors
  # pi_plan_mode_from_messages/1's "scan for the last matching event"
  # pattern, so a page reload (even against a dead runner falling back to
  # HubRPC.list_messages/1) still shows the meter. `nil` (not yet arrived, or
  # a non-pi backend that never emits this event) keeps the meter hidden.
  defp context_percent_from_messages(messages) do
    messages
    |> Enum.reverse()
    |> Enum.find_value(fn
      %{"type" => "pi_session_stats", "context_usage" => %{"percent" => p}}
      when is_number(p) ->
        MessageComponents.format_context_percent(p)

      _ ->
        nil
    end)
  end

  defp handle_context_stats_events(socket, %{
         "type" => "pi_session_stats",
         "context_usage" => %{"percent" => p}
       })
       when is_number(p) do
    assign(socket, :context_percent, MessageComponents.format_context_percent(p))
  end

  defp handle_context_stats_events(socket, _event), do: socket

  # Color thresholds for the header context meter (spec §12.8): normal below
  # 60%, warning 60-84%, error 85%+.
  defp context_meter_color(pct) when pct >= 85, do: "progress-error"
  defp context_meter_color(pct) when pct >= 60, do: "progress-warning"
  defp context_meter_color(_pct), do: "progress-primary"

  @impl true
  def handle_event("send_message", %{"prompt" => prompt}, socket) do
    Logger.info("send_message: prompt=#{inspect(String.trim(prompt))}")

    Logger.info(
      "send_message: image entries=#{length(socket.assigns.uploads.image.entries)}, " <>
        "file entries=#{length(socket.assigns.uploads.file.entries)}"
    )

    {image_paths, socket} = consume_uploaded_entries_for(socket, :image)
    {file_entries, socket} = consume_uploaded_file_entries(socket)

    Logger.info(
      "send_message: image_paths=#{inspect(image_paths)}, file_entries=#{inspect(file_entries)}"
    )

    # For remote sessions, transfer uploaded files to the remote node
    {image_paths, file_entries} =
      if remote_session?(socket) do
        session_node = socket.assigns.session_node
        session_dir = socket.assigns.session.directory

        {transfer_uploads(image_paths, session_node, session_dir),
         transfer_uploads(file_entries, session_node, session_dir)}
      else
        {image_paths, file_entries}
      end

    image_attachments =
      Enum.map(image_paths, &"[Attached image: #{&1} — use your Read tool to view it]")

    file_attachments = Enum.map(file_entries, &"[Attached file: #{&1}]")

    attachments = Enum.join(image_attachments ++ file_attachments, "\n\n")

    full_prompt =
      case {String.trim(prompt), attachments} do
        {"", ""} -> nil
        {text, ""} -> text
        {"", att} -> "I've attached files to the session directory. Please review them.\n\n#{att}"
        {text, att} -> "#{text}\n\n#{att}"
      end

    if full_prompt do
      case Cluster.send_message(
             socket.assigns.session_node,
             socket.assigns.session.id,
             full_prompt
           ) do
        :ok ->
          {:noreply, push_event(socket, "clear-prompt", %{})}

        {:error, :busy} ->
          {:noreply, put_flash(socket, :error, "Session is busy")}

        {:error, reason} ->
          message =
            Cluster.node_unavailable_message(reason) ||
              "Failed to send message: #{inspect(reason)}"

          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, socket}
    end
  end

  # -- Tree view --

  def handle_event("toggle_subagents", %{"id" => session_id}, socket) do
    subagents = socket.assigns.tree_subagents

    # <details>'s open/closed state lives client-side (native browser
    # behavior); this handler only needs to run the fetch once per session,
    # idempotently, on whichever click first opens it.
    subagents =
      if Map.has_key?(subagents, session_id) do
        subagents
      else
        Map.put(subagents, session_id, HubRPC.list_task_invocations(session_id))
      end

    {:noreply, assign(socket, :tree_subagents, subagents)}
  end

  def handle_event("open_tree_compose", %{"id" => target_id, "title" => target_title}, socket) do
    target_node_unavailable =
      case Cluster.find_session(target_id) do
        {node, _session} -> !Cluster.node_available?(node)
        nil -> true
      end

    {:noreply,
     assign(socket, :tree_compose, %{
       target_id: target_id,
       target_title: target_title,
       mode: if(target_node_unavailable, do: "relay", else: "direct"),
       target_node_unavailable: target_node_unavailable
     })}
  end

  def handle_event("close_tree_compose", _params, socket) do
    {:noreply, assign(socket, :tree_compose, nil)}
  end

  def handle_event("set_tree_compose_mode", %{"mode" => mode}, socket) do
    {:noreply, update(socket, :tree_compose, &Map.put(&1, :mode, mode))}
  end

  def handle_event("send_tree_compose", %{"text" => text}, socket) do
    case String.trim(text) do
      "" ->
        {:noreply, socket}

      text ->
        %{target_id: target_id, target_title: target_title, mode: mode} =
          socket.assigns.tree_compose

        result = send_tree_compose_message(socket, mode, target_id, target_title, text)
        {:noreply, handle_tree_compose_result(socket, result)}
    end
  end

  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("cancel-upload", %{"ref" => ref, "upload" => upload}, socket) do
    {:noreply, cancel_upload(socket, String.to_existing_atom(upload), ref)}
  end

  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :image, ref)}
  end

  def handle_event("interrupt", _params, socket) do
    Cluster.interrupt(socket.assigns.session_node, socket.assigns.session.id)
    {:noreply, socket}
  end

  # Backend-native plan-mode toggle (pi's `/plan`, spec §12.4/§12.8) — button
  # is gated on @capabilities.plan_mode_toggle (Claude/Codex never render
  # it). Optimistically flips @plan_mode immediately so the click feels
  # responsive whether the toggle applied live (warm :idle) or was only
  # QUEUED for the next spawn (:ready/:error/cold :idle, spec §12.8 — the
  # runner returns :ok either way); the authoritative `pi_plan_mode`
  # broadcast (handle_pi_plan_events/2) — fired on every `/plan` AND on every
  # `session_start`, per priv/pi/orca-plan.ts — reconciles moments later over
  # the wire regardless, including after a queued toggle's next cold spawn.
  def handle_event("toggle_plan_mode", _params, socket) do
    case Cluster.toggle_plan_mode(socket.assigns.session_node, socket.assigns.session.id) do
      :ok ->
        new_plan_mode = if socket.assigns.plan_mode == :planning, do: false, else: :planning
        {:noreply, assign(socket, :plan_mode, new_plan_mode)}

      {:error, reason} ->
        message =
          Cluster.node_unavailable_message(reason) ||
            "Can't toggle plan mode while a turn is running — wait for it to finish."

        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # Manual context compaction (pi's `compact` RPC command, spec §12.8) —
  # gated on the header context meter's own presence (@capabilities.
  # session_stats && @context_percent), same posture as toggle_plan_mode/1's
  # optimistic-then-reconciled feel, but with no local assign to flip: the
  # resulting compaction_start/compaction_end events already render via the
  # existing system_message/1 path (spec §12.6) as soon as they arrive.
  def handle_event("compact_session", _params, socket) do
    case Cluster.compact_session(socket.assigns.session_node, socket.assigns.session.id) do
      :ok ->
        {:noreply, put_flash(socket, :info, "Compaction requested")}

      {:error, reason} ->
        message =
          Cluster.node_unavailable_message(reason) ||
            "Can't compact right now — the session must be idle to compact."

        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("new_session", _params, socket) do
    session = socket.assigns.session
    target_node = socket.assigns.session_node

    params = %{
      "directory" => session.directory,
      "project_id" => session.project_id,
      "runner_node" => Atom.to_string(target_node)
    }

    case HubRPC.create_session(params) do
      {:ok, new_session} ->
        Cluster.start_session(target_node, new_session.id, new_session)

        {:noreply, push_navigate(socket, to: ~p"/sessions/#{new_session.id}")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create session")}
    end
  end

  def handle_event("toggle_tts", _params, socket) do
    {:noreply, assign(socket, :tts_autoplay, !socket.assigns.tts_autoplay)}
  end

  def handle_event("toggle_todos", _params, socket) do
    {:noreply, assign(socket, :show_todos, !socket.assigns.show_todos)}
  end

  def handle_event("toggle_commits", _params, socket) do
    {:noreply, assign(socket, :show_commits, !socket.assigns.show_commits)}
  end

  def handle_event("toggle_artifacts", _params, socket) do
    {:noreply, assign(socket, :show_artifacts, !socket.assigns.show_artifacts)}
  end

  def handle_event("open_session_artifact", %{"id" => artifact_id}, socket) do
    {:noreply, socket |> open_artifact_tab(artifact_id) |> assign(:show_artifacts, false)}
  end

  # orca.send bidirectional bridge (Artifacts Phase 3): an artifact iframe's
  # ArtifactData hook forwards its `window.orca.send(payload)` postMessage
  # here. Delivered to the session being VIEWED (not necessarily the
  # artifact's creator — reopening someone else's artifact and interacting
  # with it talks to whoever you're currently looking at), through the same
  # Cluster.send_message path a typed user message uses, so
  # running/idle/interrupt-and-queue semantics all behave identically.
  def handle_event("artifact_send", %{"artifact_id" => artifact_id, "payload" => payload}, socket) do
    if ArtifactSend.too_large?(payload) do
      {:noreply,
       put_flash(socket, :error, "Artifact interaction payload too large (max 16KB) — dropped.")}
    else
      case ArtifactSend.check_throttle(socket.assigns.artifact_send_throttle, artifact_id) do
        :throttled ->
          {:noreply,
           put_flash(socket, :error, "Artifact is sending too fast — interaction dropped.")}

        {:ok, throttle} ->
          socket
          |> assign(:artifact_send_throttle, throttle)
          |> deliver_artifact_send(artifact_id, payload)
      end
    end
  end

  def handle_event("edit_title", _params, socket) do
    {:noreply, assign(socket, :editing_title, true)}
  end

  def handle_event("cancel_title_edit", _params, socket) do
    {:noreply, assign(socket, :editing_title, false)}
  end

  def handle_event("save_title", %{"title" => title}, socket) do
    title = String.trim(title)
    session = socket.assigns.session

    case HubRPC.update_session(session, %{title: title}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:session, %{session | title: updated.title})
         |> assign(:page_title, updated.title || session.directory)
         |> assign(:editing_title, false)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update title")}
    end
  end

  def handle_event("toggle_commit_detail", %{"hash" => hash}, socket) do
    if socket.assigns[:expanded_commit] == hash do
      {:noreply, assign(socket, expanded_commit: nil, commit_detail: nil)}
    else
      detail =
        case Cluster.rpc(socket.assigns.session_node, Sessions, :get_commit_detail, [
               socket.assigns.session.directory,
               hash
             ]) do
          %{} = detail -> detail
          # node_unassigned/node_unavailable (or any other rpc failure) — no
          # detail to show rather than assigning the raw error tuple.
          _ -> nil
        end

      {:noreply, assign(socket, expanded_commit: hash, commit_detail: detail)}
    end
  end

  def handle_event("set_model", %{"model" => model}, socket) do
    session = socket.assigns.session
    model = if model == "", do: nil, else: model

    case Sessions.update_session(session, %{model: model}) do
      {:ok, updated_session} ->
        Cluster.update_model(socket.assigns.session_node, session.id, model)
        {:noreply, assign(socket, :session, updated_session)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update model")}
    end
  end

  def handle_event("set_backend", %{"backend" => backend}, socket) do
    session = socket.assigns.session

    cond do
      backend == (session.backend || "claude") ->
        {:noreply, socket}

      backend not in Enum.map(Backend.available_on(socket.assigns.session_node), &elem(&1, 0)) ->
        {:noreply,
         put_flash(socket, :error, "Backend #{backend} is not installed on this session's node")}

      true ->
        # Ask the runner first: it refuses mid-turn (the in-flight CLI process
        # belongs to the old backend), and only after it has torn down the old
        # warm process do we persist. The native resume id and model are
        # dropped with it — neither carries across backends — so the new agent
        # starts a fresh conversation; the message history stays in the UI.
        case Cluster.update_backend(socket.assigns.session_node, session.id, backend) do
          {:error, :busy} ->
            {:noreply, put_flash(socket, :error, "Can't switch backend while a turn is running")}

          :ok ->
            case Sessions.update_session(session, %{
                   backend: backend,
                   claude_session_id: nil,
                   model: nil
                 }) do
              {:ok, updated_session} ->
                {:noreply,
                 socket
                 |> assign(:session, updated_session)
                 |> assign(:capabilities, Backend.capabilities_for(updated_session))
                 |> put_flash(
                   :info,
                   "Backend switched to #{backend} — the agent starts a fresh conversation on the next message"
                 )}

              {:error, _} ->
                {:noreply, put_flash(socket, :error, "Failed to update backend")}
            end

          {:error, reason} ->
            message = Cluster.node_unavailable_message(reason) || "Failed to update backend"
            {:noreply, put_flash(socket, :error, message)}
        end
    end
  end

  def handle_event("toggle_orchestrator", _params, socket) do
    session = socket.assigns.session
    new_value = !session.orchestrator

    case Sessions.update_session(session, %{orchestrator: new_value}) do
      {:ok, updated_session} ->
        Cluster.update_orchestrator(socket.assigns.session_node, session.id, new_value)

        flash_msg =
          if new_value,
            do: "Orchestrator mode enabled (takes effect on next message)",
            else: "Orchestrator mode disabled (takes effect on next message)"

        {:noreply, socket |> assign(:session, updated_session) |> put_flash(:info, flash_msg)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update orchestrator mode")}
    end
  end

  def handle_event("change_node", %{"node" => new_node}, socket) do
    session = socket.assigns.session

    # Stop the session on the current node if it's running
    if Cluster.session_alive?(socket.assigns.session_node, session.id) do
      Cluster.stop_session(socket.assigns.session_node, session.id)
    end

    # Update the runner_node in the database
    case HubRPC.update_session(session, %{runner_node: new_node}) do
      {:ok, updated_session} ->
        # Compute the new session_node for routing
        new_session_node = Cluster.runner_node_for(updated_session)
        new_remote? = new_node != Atom.to_string(node())
        new_node_name = Cluster.node_name(new_node)

        {:noreply,
         socket
         |> assign(:session, updated_session)
         |> assign(:session_node, new_session_node)
         |> assign(:session_node_name, new_node_name)
         |> assign(:remote_session, new_remote?)
         |> put_flash(:info, "Session moved to #{new_node_name}")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to change node")}
    end
  end

  def handle_event("stop_session", _params, socket) do
    Cluster.stop_session(socket.assigns.session_node, socket.assigns.session.id)
    {:noreply, socket}
  end

  # AskUserQuestion wizard events

  def handle_event("aq_select", %{"q" => q, "label" => label} = params, socket) do
    page = String.to_integer(q)
    multi = params["multi"] == "true"

    selections =
      AskUserQuestion.toggle_selection(socket.assigns.aq_selections, page, label, multi)

    {:noreply, assign(socket, :aq_selections, selections)}
  end

  def handle_event("aq_prev", _params, socket) do
    {:noreply, assign(socket, :aq_page, max(socket.assigns.aq_page - 1, 0))}
  end

  def handle_event("aq_next", _params, socket) do
    max_page = length(pending_question_list(socket)) - 1
    {:noreply, assign(socket, :aq_page, min(socket.assigns.aq_page + 1, max_page))}
  end

  def handle_event("aq_cancel", _params, socket) do
    {:noreply, assign(socket, :aq_open, false)}
  end

  # pi extension-UI dialog events (spec §12.3 — the pi analogue of the
  # aq_* handlers above, but answering through SessionRunner.answer_ui_request/3
  # — a direct port write of `extension_ui_response` — instead of a plain
  # chat message, since that's the wire protocol pi's blocked `ctx.ui.select`/
  # `ctx.ui.input` call is actually waiting on). Fired either by clicking one
  # of the option buttons (`phx-value-*` attrs, all flat string params) or by
  # submitting the free-form text form (same param shape, "value" from the
  # text input). Clears `:pending_ui_request` optimistically — the
  # authoritative clear still arrives via the runner's "pi_ui_response"
  # broadcast (handle_pi_ui_events/2), so a mismatched/late click is harmless.
  def handle_event(
        "piui_answer",
        %{"request_id" => request_id, "method" => method, "value" => value},
        socket
      ) do
    payload = piui_payload(method, value)

    Cluster.answer_ui_request(
      socket.assigns.session_node,
      socket.assigns.session.id,
      request_id,
      payload
    )

    {:noreply, assign(socket, :pending_ui_request, nil)}
  end

  def handle_event("piui_cancel", %{"request_id" => request_id}, socket) do
    Cluster.answer_ui_request(
      socket.assigns.session_node,
      socket.assigns.session.id,
      request_id,
      %{"cancelled" => true}
    )

    {:noreply, assign(socket, :pending_ui_request, nil)}
  end

  def handle_event("aq_submit", _params, socket) do
    case socket.assigns.pending_questions do
      %{questions: questions} ->
        prompt = AskUserQuestion.format_answers(questions, socket.assigns.aq_selections)
        Cluster.send_message(socket.assigns.session_node, socket.assigns.session.id, prompt)

        {:noreply,
         socket
         |> assign(:aq_open, false)
         |> assign(:aq_page, 0)
         |> assign(:aq_selections, %{})}

      _ ->
        {:noreply, assign(socket, :aq_open, false)}
    end
  end

  # MCP server events

  def handle_event("toggle_mcp_modal", _params, socket) do
    {:noreply,
     assign(socket, show_mcp_modal: !socket.assigns.show_mcp_modal, show_mcp_server_picker: false)}
  end

  def handle_event("toggle_mcp_server_picker", _params, socket) do
    {:noreply, assign(socket, show_mcp_server_picker: !socket.assigns.show_mcp_server_picker)}
  end

  def handle_event("add_mcp_server", %{"id" => server_id}, socket) do
    session_id = socket.assigns.session.id
    HubRPC.add_server_to_session(session_id, server_id)

    {:noreply,
     socket
     |> assign(
       session_mcp_servers: HubRPC.list_servers_for_session(session_id),
       show_mcp_server_picker: false
     )
     |> put_flash(:info, "MCP server added — takes effect on next run")}
  end

  def handle_event("remove_mcp_server", %{"id" => server_id}, socket) do
    session_id = socket.assigns.session.id
    HubRPC.remove_server_from_session(session_id, server_id)

    {:noreply,
     socket
     |> assign(session_mcp_servers: HubRPC.list_servers_for_session(session_id))
     |> put_flash(:info, "MCP server removed")}
  end

  # Heartbeat events

  def handle_event("toggle_heartbeat_modal", _params, socket) do
    {:noreply, assign(socket, show_heartbeat_modal: !socket.assigns.show_heartbeat_modal)}
  end

  def handle_event(
        "schedule_heartbeat",
        %{"interval" => interval_str, "message" => message},
        socket
      ) do
    session_id = socket.assigns.session.id

    with {interval, ""} <- Integer.parse(interval_str),
         :ok <- HubRPC.schedule_heartbeat(session_id, interval, "[Heartbeat]\n\n#{message}") do
      {:noreply,
       socket
       |> assign(heartbeat_info: HubRPC.get_heartbeat(session_id))
       |> assign(show_heartbeat_modal: false)
       |> put_flash(:info, "Heartbeat scheduled: every #{format_interval(interval)}")}
    else
      :error ->
        {:noreply, put_flash(socket, :error, "Invalid interval")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to schedule heartbeat: #{reason}")}
    end
  end

  def handle_event("cancel_heartbeat", _params, socket) do
    session_id = socket.assigns.session.id
    HubRPC.cancel_heartbeat(session_id)

    {:noreply,
     socket
     |> assign(heartbeat_info: nil)
     |> put_flash(:info, "Heartbeat cancelled")}
  end

  def handle_event("archive", _params, socket) do
    session = socket.assigns.session
    Cluster.stop_session(socket.assigns.session_node, session.id)
    {:ok, _} = Cluster.archive_session(socket.assigns.session_node, session)
    {:noreply, push_navigate(socket, to: ~p"/sessions?undo=#{session.id}")}
  end

  def handle_event("unarchive", _params, socket) do
    session = socket.assigns.session
    {:ok, session} = Cluster.unarchive_session(socket.assigns.session_node, session)
    {:noreply, assign(socket, :session, session)}
  end

  def handle_event("approve_plan", _params, socket) do
    plan_edited? = plan_file_was_edited?(socket)

    prompt =
      if plan_edited? do
        "The plan has been edited by the user. Please re-read the plan file and review the changes before proceeding with implementation."
      else
        "The plan looks good. Please exit plan mode and proceed with implementation."
      end

    case Cluster.send_message(socket.assigns.session_node, socket.assigns.session.id, prompt) do
      :ok ->
        {:noreply,
         assign(socket, plan_mode: false, plan_file_path: nil, plan_file_original_mtime: nil)}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send message: #{inspect(reason)}")}
    end
  end

  def handle_event("reject_plan", _params, socket) do
    # Clear plan review — user can type their feedback in the prompt
    {:noreply,
     assign(socket, plan_mode: false, plan_file_path: nil, plan_file_original_mtime: nil)}
  end

  def handle_event("commit", _params, socket) do
    session_id = socket.assigns.session.id

    prompt =
      "Commit the changes you made in this session. Only stage files you actually modified — do not use `git add -A` or `git add .`. Use a descriptive commit message based on the diff. Remember to include the trailer: OrcaHub-Session: #{session_id}"

    case Cluster.send_message(socket.assigns.session_node, session_id, prompt) do
      :ok ->
        {:noreply, socket}

      {:error, :busy} ->
        {:noreply, put_flash(socket, :error, "Session is busy")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to send message: #{inspect(reason)}")}
    end
  end

  # -- Autocomplete events --

  def handle_event("autocomplete", %{"type" => "command", "query" => query}, socket) do
    commands = [
      %{
        label: "/commit",
        value: "/commit",
        hint: "Commit changes",
        action: "commit",
        type: "command",
        icon: "hero-check"
      },
      %{
        label: "/new",
        value: "/new",
        hint: "New session in same directory",
        action: "new_session",
        type: "command",
        icon: "hero-plus-circle"
      },
      %{
        label: "/clear",
        value: "/clear",
        hint: "Clear conversation",
        action: "clear",
        type: "command",
        icon: "hero-trash"
      },
      %{
        label: "/model",
        value: "/model ",
        hint: "Change model",
        type: "command",
        icon: "hero-cpu-chip"
      }
    ]

    filtered =
      if query == "" do
        commands
      else
        query_lower = String.downcase(query)

        Enum.filter(commands, fn cmd ->
          String.contains?(String.downcase(cmd.label), query_lower)
        end)
      end

    {:noreply, push_event(socket, "autocomplete_results", %{items: filtered, type: "command"})}
  end

  def handle_event("autocomplete", %{"type" => "file", "query" => query}, socket) do
    dir = socket.assigns.session.directory
    project = %Projects.Project{directory: dir}

    # Get flat file list and filter
    session_node = socket.assigns[:session_node] || node()

    files =
      case Cluster.rpc(session_node, Projects, :list_editable_files, [project]) do
        list when is_list(list) -> list
        # node_unassigned/node_unavailable (or any other rpc failure) — no
        # files to suggest rather than crashing on a non-list Enum.filter/2.
        _ -> []
      end

    filtered =
      if query == "" do
        Enum.take(files, 10)
      else
        query_lower = String.downcase(query)

        files
        |> Enum.filter(fn path ->
          String.contains?(String.downcase(path), query_lower)
        end)
        |> Enum.take(10)
      end

    items =
      Enum.map(filtered, fn path ->
        %{
          label: path,
          value: "@#{path}",
          hint: Path.dirname(path),
          type: "file"
        }
      end)

    {:noreply, push_event(socket, "autocomplete_results", %{items: items, type: "file"})}
  end

  def handle_event("autocomplete", %{"type" => "session", "query" => query}, socket) do
    # Search sessions, preferring same project
    opts = %{limit: 10, include_archived: false}

    sessions =
      if query == "" do
        # When no query, show sessions from the same project/directory
        HubRPC.search_sessions_by_directory(socket.assigns.session.directory, opts)
      else
        HubRPC.search_all_sessions(Map.put(opts, :query, query))
      end

    # Filter out current session
    current_id = socket.assigns.session.id

    items =
      sessions
      |> Enum.reject(&(&1.id == current_id))
      |> Enum.map(fn s ->
        label = s.title || Path.basename(s.directory)
        hint = if s.project, do: s.project.name, else: Path.basename(s.directory)

        %{
          label: label,
          value: s.id,
          hint: hint,
          type: "session"
        }
      end)

    {:noreply, push_event(socket, "autocomplete_results", %{items: items, type: "session"})}
  end

  def handle_event("autocomplete", %{"type" => "project", "query" => query}, socket) do
    projects =
      if query == "" do
        HubRPC.list_projects() |> Enum.take(10)
      else
        HubRPC.search_projects(query)
      end

    items =
      Enum.map(projects, fn p ->
        %{
          label: p.name,
          value: "###{p.name}",
          hint: Path.basename(p.directory),
          type: "project"
        }
      end)

    {:noreply, push_event(socket, "autocomplete_results", %{items: items, type: "project"})}
  end

  def handle_event("autocomplete_action", %{"action" => "commit"}, socket) do
    handle_event("commit", %{}, socket)
  end

  def handle_event("autocomplete_action", %{"action" => "new_session"}, socket) do
    handle_event("new_session", %{}, socket)
  end

  def handle_event("autocomplete_action", %{"action" => "clear"}, socket) do
    # Clear is a no-op for now - would need to implement message clearing
    {:noreply, put_flash(socket, :info, "Clear not implemented yet")}
  end

  def handle_event("autocomplete_action", _params, socket) do
    {:noreply, socket}
  end

  def handle_event("open_terminal", _params, socket) do
    if socket.assigns.show_terminal do
      {:noreply, assign(socket, show_terminal: false)}
    else
      session = socket.assigns.session
      session_node = socket.assigns.session_node

      if socket.assigns.open_terminals != [] do
        # Panel was just hidden, show it again
        {:noreply, assign(socket, show_terminal: true)}
      else
        # Find or create a terminal
        {:noreply, open_or_create_terminal(socket, session, session_node)}
      end
    end
  end

  def handle_event("new_terminal", _params, socket) do
    session = socket.assigns.session
    session_node = socket.assigns.session_node
    count = length(socket.assigns.open_terminals) + 1

    name =
      if session.project do
        "#{session.project.name} shell #{count}"
      else
        "shell #{count}"
      end

    terminal_attrs = build_terminal_attrs(name, session, session_node)

    case Cluster.create_terminal(session_node, terminal_attrs) do
      {:ok, terminal} ->
        Cluster.start_terminal(session_node, terminal.id)
        terminal = Cluster.get_terminal!(session_node, terminal.id)

        {:noreply,
         socket
         |> assign(:open_terminals, socket.assigns.open_terminals ++ [terminal])
         |> assign(:active_terminal_id, terminal.id)}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create terminal")}
    end
  end

  def handle_event("switch_terminal", %{"id" => id}, socket) do
    {:noreply, assign(socket, :active_terminal_id, id)}
  end

  def handle_event("close_terminal_tab", %{"id" => id}, socket) do
    open = Enum.reject(socket.assigns.open_terminals, &(&1.id == id))

    active =
      cond do
        open == [] -> nil
        socket.assigns.active_terminal_id == id -> hd(open).id
        true -> socket.assigns.active_terminal_id
      end

    socket = assign(socket, open_terminals: open, active_terminal_id: active)
    socket = if open == [], do: assign(socket, show_terminal: false), else: socket
    {:noreply, socket}
  end

  def handle_event("close_terminal_panel", _params, socket) do
    {:noreply, assign(socket, show_terminal: false)}
  end

  def handle_event("pop_out_terminal", _params, socket) do
    active_id = socket.assigns.active_terminal_id

    if active_id do
      {:noreply, push_navigate(socket, to: ~p"/terminals/#{active_id}")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("resume_in_terminal", _params, socket) do
    session = socket.assigns.session

    if session.claude_session_id do
      {:noreply, resume_session_in_terminal(socket, session)}
    else
      {:noreply, put_flash(socket, :error, "No Claude session to resume")}
    end
  end

  # -- File panel events --

  def handle_event("toggle_file_browser", _params, socket) do
    {:noreply, assign(socket, :show_file_browser, !socket.assigns.show_file_browser)}
  end

  def handle_event("switch_tab", %{"path" => path}, socket) do
    tab = Enum.find(socket.assigns.open_files, &(&1.path == path))

    if tab do
      {:noreply,
       socket
       |> assign(:active_file_tab, path)
       |> assign(:file_editing, false)
       |> assign(:file_edit_mode, false)
       |> assign(:editing_block, nil)
       |> assign(:scroll_to_line, nil)
       |> assign(:scroll_to_block, nil)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("close_tab", %{"path" => path}, socket) do
    closing = Enum.find(socket.assigns.open_files, &(&1.path == path))
    open_files = Enum.reject(socket.assigns.open_files, &(&1.path == path))

    active =
      cond do
        open_files == [] -> nil
        socket.assigns.active_file_tab == path -> hd(open_files).path
        true -> socket.assigns.active_file_tab
      end

    socket =
      case closing do
        %{kind: :artifact, artifact_id: id} -> unsubscribe_artifact(socket, id)
        _ -> socket
      end

    {:noreply,
     socket
     |> assign(:open_files, open_files)
     |> assign(:active_file_tab, active)
     |> assign(:file_editing, false)
     |> assign(:editing_block, nil)
     |> assign(:file_mtimes, Map.delete(socket.assigns.file_mtimes, path))}
  end

  def handle_event("close_file_panel", _params, socket) do
    socket =
      Enum.reduce(socket.assigns.open_files, socket, fn
        %{kind: :artifact, artifact_id: id}, acc -> unsubscribe_artifact(acc, id)
        _tab, acc -> acc
      end)

    {:noreply,
     socket
     |> assign(:open_files, [])
     |> assign(:active_file_tab, nil)
     |> assign(:file_editing, false)
     |> assign(:editing_block, nil)
     |> assign(:show_file_browser, false)}
  end

  def handle_event("toggle_edit_mode", _params, socket) do
    {:noreply,
     assign(socket,
       file_edit_mode: !socket.assigns.file_edit_mode,
       file_editing: false,
       editing_block: nil
     )}
  end

  def handle_event("edit_file", _params, socket) do
    {:noreply, assign(socket, :file_editing, true)}
  end

  def handle_event("cancel_edit_file", _params, socket) do
    {:noreply, assign(socket, file_editing: false, editing_block: nil)}
  end

  def handle_event("save_file", %{"content" => content}, socket) do
    path = socket.assigns.active_file_tab
    blocks = if Projects.markdown_file?(path), do: Markdown.split_blocks(content), else: []

    save_file_and_update(
      socket,
      path,
      content,
      blocks,
      [file_editing: false, editing_block: nil],
      "Save failed"
    )
  end

  def handle_event("edit_block", %{"index" => index}, socket) do
    index = String.to_integer(index)
    tab = get_active_tab(socket)

    block_text =
      case Enum.find(tab.blocks, fn {idx, _} -> idx == index end) do
        {_, text} -> text
        nil -> ""
      end

    {:noreply, assign(socket, editing_block: index, block_edit_content: block_text)}
  end

  def handle_event("cancel_block_edit", _params, socket) do
    {:noreply, assign(socket, editing_block: nil, block_edit_content: nil)}
  end

  def handle_event("save_block", %{"content" => content}, socket) do
    tab = get_active_tab(socket)
    index = socket.assigns.editing_block

    updated_blocks =
      Enum.map(tab.blocks, fn {idx, text} ->
        if idx == index, do: {idx, String.trim(content)}, else: {idx, text}
      end)

    full_content = Markdown.join_blocks(updated_blocks)

    save_file_and_update(
      socket,
      tab.path,
      full_content,
      updated_blocks,
      [editing_block: nil, block_edit_content: nil],
      "Save failed"
    )
  end

  def handle_event("delete_block", %{"index" => index}, socket) do
    tab = get_active_tab(socket)
    index = String.to_integer(index)

    updated_blocks = Enum.reject(tab.blocks, fn {idx, _} -> idx == index end)
    full_content = Markdown.join_blocks(updated_blocks)

    save_file_and_update(
      socket,
      tab.path,
      full_content,
      updated_blocks,
      [editing_block: nil],
      "Delete failed"
    )
  end

  # Mode 1, "direct": delivered to the TARGET session exactly like typing
  # into that session's own composer — Cluster.send_message already
  # restarts a dead runner and unarchives on send (SessionRunner's
  # start_running/3), same as send_message_to_session and the main composer
  # above.
  defp send_tree_compose_message(_socket, "direct", target_id, _target_title, text) do
    case Cluster.find_session(target_id) do
      {node, _session} -> Cluster.send_message(node, target_id, text)
      nil -> {:error, :not_found}
    end
  end

  # Mode 2, "relay": nudges the CURRENT session (the one whose page we're
  # on) to use its own send_message_to_session MCP tool — as a side effect,
  # that records a session_interactions edge automatically.
  defp send_tree_compose_message(socket, "relay", target_id, target_title, text) do
    nudge = "Please message session #{target_id} (#{target_title}) about the following: #{text}"
    Cluster.send_message(socket.assigns.session_node, socket.assigns.session.id, nudge)
  end

  defp handle_tree_compose_result(socket, :ok) do
    socket |> assign(:tree_compose, nil) |> put_flash(:info, "Message sent.")
  end

  defp handle_tree_compose_result(socket, {:error, :not_found}) do
    put_flash(socket, :error, "That session could not be found.")
  end

  defp handle_tree_compose_result(socket, {:error, :busy}) do
    put_flash(socket, :error, "Session is busy")
  end

  defp handle_tree_compose_result(socket, {:error, reason}) do
    message =
      Cluster.node_unavailable_message(reason) || "Failed to send message: #{inspect(reason)}"

    put_flash(socket, :error, message)
  end

  # Persists `content` to `path` on the session's node, then either updates the
  # matching open-file tab (content, blocks, mtime) plus `success_assigns`, or
  # flashes an error prefixed with `error_label`. Shared by the save_file,
  # save_block, and delete_block events.
  defp save_file_and_update(socket, path, content, blocks, success_assigns, error_label) do
    dir = socket.assigns.session.directory
    project = %Projects.Project{directory: dir}
    session_node = socket.assigns[:session_node] || node()

    case Cluster.rpc(session_node, Projects, :save_file, [project, path, content]) do
      :ok ->
        mtime = remote_file_mtime(session_node, Path.join(dir, path))
        open_files = update_open_file_tab(socket.assigns.open_files, path, content, blocks)

        {:noreply,
         socket
         |> assign(Keyword.put(success_assigns, :open_files, open_files))
         |> assign(:file_mtimes, Map.put(socket.assigns.file_mtimes, path, mtime))}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "#{error_label}: #{inspect(reason)}")}
    end
  end

  # Returns `open_files` with the tab matching `path` updated to the new
  # content and blocks; other tabs are left unchanged.
  defp update_open_file_tab(open_files, path, content, blocks) do
    Enum.map(open_files, fn tab ->
      if tab.path == path, do: %{tab | content: content, blocks: blocks}, else: tab
    end)
  end

  defp resume_session_in_terminal(socket, session) do
    session_node = socket.assigns.session_node
    cmd = "claude --resume #{session.claude_session_id}\n"

    # Create a dedicated terminal for this Claude session
    name = if session.title, do: "claude: #{session.title}", else: "claude resume"

    case Cluster.create_terminal(session_node, build_terminal_attrs(name, session, session_node)) do
      {:ok, terminal} ->
        Cluster.start_terminal(session_node, terminal.id)
        terminal = Cluster.get_terminal!(session_node, terminal.id)

        # Send the resume command after a brief delay for the shell to
        # initialize. Scheduled non-blocking so the LiveView stays responsive.
        Process.send_after(
          self(),
          {:resume_terminal_write, session_node, terminal.id, cmd},
          500
        )

        socket
        |> assign(:show_terminal, true)
        |> assign(:open_terminals, socket.assigns.open_terminals ++ [terminal])
        |> assign(:active_terminal_id, terminal.id)

      {:error, _} ->
        put_flash(socket, :error, "Failed to create terminal")
    end
  end

  defp build_terminal_attrs(name, session, session_node) do
    %{
      name: name,
      directory: session.directory,
      project_id: session.project_id,
      runner_node: Atom.to_string(session_node)
    }
  end

  defp open_or_create_terminal(socket, session, session_node) do
    tagged = Cluster.list_terminals_for_project(session.project_id)

    candidates =
      Enum.filter(tagged, fn {_n, t} ->
        t.directory == session.directory && t.status != "stopped"
      end)

    live =
      Enum.find(candidates, fn {n, t} ->
        Cluster.terminal_alive?(n, t.id)
      end)

    case live || List.first(candidates) do
      nil ->
        name =
          if session.project do
            "#{session.project.name} shell"
          else
            "shell"
          end

        case Cluster.create_terminal(
               session_node,
               build_terminal_attrs(name, session, session_node)
             ) do
          {:ok, terminal} ->
            Cluster.start_terminal(session_node, terminal.id)
            terminal = Cluster.get_terminal!(session_node, terminal.id)

            socket
            |> assign(:show_terminal, true)
            |> assign(:open_terminals, [terminal])
            |> assign(:active_terminal_id, terminal.id)

          {:error, reason} ->
            message = Cluster.node_unavailable_message(reason) || "Failed to create terminal"
            put_flash(socket, :error, message)
        end

      {n, terminal} ->
        runner_node = Cluster.runner_node_for(terminal)

        cond do
          Cluster.terminal_alive?(runner_node, terminal.id) ->
            socket
            |> assign(:show_terminal, true)
            |> assign(:open_terminals, [terminal])
            |> assign(:active_terminal_id, terminal.id)

          Cluster.node_available?(runner_node) ->
            Cluster.start_terminal(runner_node, terminal.id)
            terminal = Cluster.get_terminal!(n, terminal.id)

            socket
            |> assign(:show_terminal, true)
            |> assign(:open_terminals, [terminal])
            |> assign(:active_terminal_id, terminal.id)

          true ->
            put_flash(
              socket,
              :error,
              Cluster.node_unavailable_message({:node_unavailable, runner_node})
            )
        end
    end
  end

  @impl true
  def handle_info({:open_file, path, line}, socket) do
    {:noreply, open_file_tab(socket, path, line)}
  end

  def handle_info({:open_file, path}, socket) do
    {:noreply, open_file_tab(socket, path)}
  end

  def handle_info({:file_selected, path}, socket) do
    {:noreply, open_file_tab(socket, path)}
  end

  def handle_info({:open_artifact, artifact_id, "full"}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/artifacts/#{artifact_id}")}
  end

  def handle_info({:open_artifact, artifact_id, _mode}, socket) do
    {:noreply, open_artifact_tab(socket, artifact_id)}
  end

  def handle_info({:artifact_updated, artifact}, socket) do
    open_files =
      Enum.map(socket.assigns.open_files, fn
        %{kind: :artifact, artifact_id: id} = tab when id == artifact.id ->
          %{tab | artifact: artifact}

        tab ->
          tab
      end)

    {:noreply, assign(socket, :open_files, open_files)}
  end

  # Keeps the header Artifacts button (count badge + dropdown) fresh when the
  # agent calls save_artifact mid-session — without this, @session_artifacts
  # is a one-time snapshot from mount/2 and only catches up on a page reload.
  # Upserts by id instead of re-querying: the broadcast payload already has
  # everything the dropdown renders.
  def handle_info({:artifact_saved, artifact}, socket) do
    session_artifacts =
      case Enum.find_index(socket.assigns.session_artifacts, &(&1.id == artifact.id)) do
        nil -> [artifact | socket.assigns.session_artifacts]
        index -> List.replace_at(socket.assigns.session_artifacts, index, artifact)
      end

    {:noreply, assign(socket, :session_artifacts, session_artifacts)}
  end

  # Live-data push (OrcaHub.Artifacts.update_artifact_data/2) — distinct from
  # {:artifact_updated, ...} above: no version bump, so no iframe reload.
  # Forwarded to the ArtifactData hook via push_event; the hook filters by
  # artifact_id, so this is broadcast even when no matching tab is open (the
  # hook simply has nothing to catch it).
  def handle_info({:artifact_data_updated, artifact}, socket) do
    open_files =
      Enum.map(socket.assigns.open_files, fn
        %{kind: :artifact, artifact_id: id} = tab when id == artifact.id ->
          %{tab | artifact: artifact}

        tab ->
          tab
      end)

    {:noreply,
     socket
     |> assign(:open_files, open_files)
     |> push_event("artifact_data_updated", %{artifact_id: artifact.id, data: artifact.data})}
  end

  @impl true
  def handle_info({:event, event}, socket) do
    socket = assign(socket, :messages, socket.assigns.messages ++ [event])
    socket = handle_plan_events(socket, event)
    socket = handle_todo_events(socket, event)
    socket = handle_pi_ui_events(socket, event)
    socket = handle_pi_plan_events(socket, event)
    socket = handle_context_stats_events(socket, event)
    socket = socket |> refresh_pending_questions() |> sync_question_modal()
    {:noreply, socket}
  end

  # spec §12.6 — pi's pending steer/follow-up queue changed. Transient
  # display state only (see the :pi_queue assign in mount/2) — never touches
  # @messages.
  @impl true
  def handle_info({:queue_update, steering, follow_up}, socket) do
    {:noreply, assign(socket, :pi_queue, %{steering: steering, follow_up: follow_up})}
  end

  @impl true
  def handle_info({:progress, phase, note}, socket) do
    session = %{socket.assigns.session | progress_phase: phase, progress_note: note}
    {:noreply, assign(socket, :session, session)}
  end

  @impl true
  def handle_info({:status, status}, socket) do
    socket =
      socket |> assign(:status, status) |> refresh_pending_questions() |> sync_question_modal()

    socket =
      if status == :idle do
        socket = load_session_commits(socket)

        if socket.assigns.tts_autoplay do
          push_event(socket, "tts-autoplay", %{})
        else
          socket
        end
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:title_updated, title}, socket) do
    session = %{socket.assigns.session | title: title}
    {:noreply, socket |> assign(:session, session) |> assign(:page_title, title)}
  end

  @impl true
  def handle_info(:poll_file_changes, socket) do
    if socket.assigns.remote_session do
      {:noreply, socket}
    else
      Process.send_after(self(), :poll_file_changes, 2000)

      if socket.assigns.open_files == [] do
        {:noreply, socket}
      else
        {:noreply, refresh_changed_files(socket)}
      end
    end
  end

  @impl true
  def handle_info({:resume_terminal_write, session_node, terminal_id, cmd}, socket) do
    # Offload the RPC write so the LiveView process is never blocked.
    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      Cluster.rpc(session_node, OrcaHub.TerminalRunner, :write, [terminal_id, cmd])
    end)

    {:noreply, socket}
  end

  # Aggregate "sessions" topic (see Sessions.archive_session/1,
  # SessionRunner's broadcast/2) — some OTHER session in the tree changed
  # status/archived state. Shaped `{session_id, payload}`, distinguished
  # from this session's own `{:atom, ...}` topic events above by the guard:
  # only fires while the tree view is actually mounted, and just reloads
  # the whole tree rather than diffing (same "simplest correct approach for
  # a read-mostly view" call the old /sessions/tree page made).
  @impl true
  def handle_info({session_id, _payload}, socket) when is_binary(session_id) do
    if socket.assigns.view == :tree do
      {:noreply, load_tree_data(socket)}
    else
      {:noreply, socket}
    end
  end

  # Catch-all: ignore unexpected messages so the LiveView never crashes.
  @impl true
  def handle_info(_msg, socket), do: {:noreply, socket}

  # Auto-archive sessions that were opened and abandoned without a single
  # message (one-click creation paths make these easy to accumulate). The
  # check is DELAYED and viewer-guarded rather than done inline: on a page
  # reload the dying LiveView's terminate fires while (or just before) the
  # replacement LiveView is mounting, and an inline stop/archive here used to
  # kill the freshly started runner under the user (noproc on send) and
  # archive the session they were still looking at.
  @impl true
  def terminate(_reason, socket) do
    if session = socket.assigns[:session] do
      session_node = socket.assigns[:session_node] || node()
      schedule_abandoned_cleanup(session.id, session_node)
    end
  end

  defp schedule_abandoned_cleanup(session_id, session_node) do
    delay = Application.get_env(:orca_hub, :abandoned_session_cleanup_ms, 30_000)

    Task.Supervisor.start_child(OrcaHub.TaskSupervisor, fn ->
      Process.sleep(delay)
      abandoned_cleanup(session_id, session_node)
    end)
  end

  # Public (@doc false) as a test seam. Stops + archives the session only if
  # it is STILL untouched (no messages) and nobody is viewing it anymore.
  @doc false
  def abandoned_cleanup(session_id, session_node) do
    with [] <- Registry.lookup(OrcaHub.SessionViewersRegistry, session_id),
         session when not is_nil(session) <- HubRPC.get_session(session_id),
         true <- is_nil(session.archived_at),
         [] <- Cluster.list_messages(session_node, session_id) do
      Cluster.stop_session(session_node, session_id)
      Cluster.archive_session(session_node, session)
      :archived
    else
      _ -> :kept
    end
  rescue
    # Best-effort cleanup — a dead node or DB hiccup must not produce noise.
    _ -> :kept
  end

  defp transfer_uploads(paths, target_node, session_dir) do
    upload_dir = Path.join(session_dir, ".orca_uploads")

    # Create upload directory on remote node
    Cluster.rpc(target_node, File, :mkdir_p, [upload_dir])

    Enum.flat_map(paths, fn local_path ->
      content = File.read!(local_path)
      filename = Path.basename(local_path)
      remote_path = Path.join(upload_dir, filename)

      case Cluster.rpc(target_node, File, :write, [remote_path, content]) do
        :ok ->
          File.rm(local_path)
          [remote_path]

        error ->
          Logger.warning(
            "Failed to transfer upload #{filename} to #{target_node}: #{inspect(error)}"
          )

          File.rm(local_path)
          []
      end
    end)
  end

  defp upload_error_to_string(:too_large), do: "File is too large"
  defp upload_error_to_string(:not_accepted), do: "Invalid file type"
  defp upload_error_to_string(:too_many_files), do: "Too many files"
  defp upload_error_to_string(err), do: "Upload error: #{inspect(err)}"

  defp consume_uploaded_entries_for(socket, upload_name) do
    case uploaded_entries(socket, upload_name) do
      {[_ | _], _} ->
        upload_dir = uploads_dir(socket)

        paths =
          consume_uploaded_entries(socket, upload_name, fn %{path: tmp_path}, entry ->
            ext = Path.extname(entry.client_name)
            filename = "upload_#{System.unique_integer([:positive, :monotonic])}#{ext}"
            dest = Path.join(upload_dir, filename)
            Logger.info("#{upload_name} upload: #{entry.client_name} -> #{dest}")
            File.cp!(tmp_path, dest)
            {:ok, dest}
          end)

        {paths, socket}

      _ ->
        {[], socket}
    end
  end

  defp consume_uploaded_file_entries(socket) do
    case uploaded_entries(socket, :file) do
      {[_ | _], _} ->
        upload_dir = uploads_dir(socket)

        entries =
          consume_uploaded_entries(socket, :file, fn %{path: tmp_path}, entry ->
            ext = Path.extname(entry.client_name)
            filename = "upload_#{System.unique_integer([:positive, :monotonic])}#{ext}"
            dest = Path.join(upload_dir, filename)
            Logger.info("file upload: #{entry.client_name} -> #{dest}")
            File.cp!(tmp_path, dest)
            {:ok, dest}
          end)

        {entries, socket}

      _ ->
        {[], socket}
    end
  end

  # Returns the uploads directory for the session, creating it if necessary.
  # For remote sessions, this returns a local temp path; files are transferred
  # to the remote node's persistent uploads dir by transfer_uploads/3.
  defp uploads_dir(socket) do
    if remote_session?(socket) do
      # For remote sessions, save locally first - transfer_uploads will move to remote
      "/tmp"
    else
      dir = Path.join(socket.assigns.session.directory, ".orca_uploads")
      File.mkdir_p!(dir)
      dir
    end
  end

  # -- Artifact tab helpers --

  # Artifact tabs share the same `open_files`/`active_file_tab` tab strip as
  # file tabs (switch_tab/close_tab/close_file_panel all key off `tab.path`,
  # which works unchanged here since "artifact:<id>" is a distinct fake
  # path), tagged `kind: :artifact` so the content area renders the
  # sandboxed iframe instead of file content.
  defp deliver_artifact_send(socket, artifact_id, payload) do
    case HubRPC.get_artifact(artifact_id) do
      nil ->
        {:noreply, put_flash(socket, :error, "Artifact not found.")}

      artifact ->
        message = ArtifactSend.format_message(artifact.name, payload)

        case Cluster.send_message(socket.assigns.session_node, socket.assigns.session.id, message) do
          :ok ->
            {:noreply, put_flash(socket, :info, "Sent to session.")}

          {:error, reason} ->
            error_message =
              Cluster.node_unavailable_message(reason) ||
                "Failed to send artifact interaction: #{inspect(reason)}"

            {:noreply, put_flash(socket, :error, error_message)}
        end
    end
  end

  defp open_artifact_tab(socket, artifact_id) do
    path = "artifact:#{artifact_id}"

    case Enum.find(socket.assigns.open_files, &(&1.path == path)) do
      tab when not is_nil(tab) ->
        socket |> assign(:active_file_tab, path) |> assign(:show_file_browser, false)

      nil ->
        case HubRPC.get_artifact(artifact_id) do
          nil ->
            put_flash(socket, :error, "Artifact not found.")

          artifact ->
            tab = %{
              kind: :artifact,
              path: path,
              artifact_id: artifact.id,
              artifact: artifact,
              read_only: true
            }

            socket
            |> assign(:open_files, socket.assigns.open_files ++ [tab])
            |> assign(:active_file_tab, path)
            |> assign(:show_file_browser, false)
            |> subscribe_artifact(artifact.id)
        end
    end
  end

  defp subscribe_artifact(socket, artifact_id) do
    if connected?(socket) and
         not MapSet.member?(socket.assigns.subscribed_artifact_ids, artifact_id) do
      Phoenix.PubSub.subscribe(OrcaHub.PubSub, "artifact:#{artifact_id}")

      assign(
        socket,
        :subscribed_artifact_ids,
        MapSet.put(socket.assigns.subscribed_artifact_ids, artifact_id)
      )
    else
      socket
    end
  end

  defp unsubscribe_artifact(socket, artifact_id) do
    if MapSet.member?(socket.assigns.subscribed_artifact_ids, artifact_id) do
      Phoenix.PubSub.unsubscribe(OrcaHub.PubSub, "artifact:#{artifact_id}")

      assign(
        socket,
        :subscribed_artifact_ids,
        MapSet.delete(socket.assigns.subscribed_artifact_ids, artifact_id)
      )
    else
      socket
    end
  end

  # Shared by the desktop and mobile split-panel templates (both are always
  # present in the DOM simultaneously, toggled by responsive CSS classes —
  # not conditionally rendered — so `variant` keeps their iframe ids from
  # colliding). `?v=<version>` busts the iframe's cache so a live-reload
  # (handle_info({:artifact_updated, ...})) actually re-fetches instead of
  # serving the old cached document.
  defp artifact_tab_panel(assigns) do
    ~H"""
    <div class="flex flex-col h-full min-h-0">
      <div class="flex items-center justify-between gap-2 mb-3 shrink-0">
        <div class="flex items-center gap-2 min-w-0">
          <.icon name="hero-sparkles-micro" class="size-4 text-primary shrink-0" />
          <span class="font-medium truncate">{@tab.artifact.name}</span>
          <span class="badge badge-xs badge-outline">{@tab.artifact.kind}</span>
          <span class="badge badge-xs badge-ghost">v{@tab.artifact.version}</span>
        </div>
        <.link
          navigate={~p"/artifacts/#{@tab.artifact_id}"}
          class="btn btn-xs btn-ghost gap-1 shrink-0"
          title="Open fullscreen"
        >
          <.icon name="hero-arrows-pointing-out-micro" class="size-3" /> Fullscreen
        </.link>
      </div>
      <iframe
        id={"artifact-iframe-#{@variant}-#{@tab.artifact_id}"}
        src={~p"/artifacts/#{@tab.artifact_id}/raw?v=#{@tab.artifact.version}"}
        sandbox="allow-scripts"
        title={@tab.artifact.name}
        phx-hook="ArtifactData"
        data-artifact-id={@tab.artifact_id}
        class="flex-1 w-full min-h-0 bg-white rounded border border-base-300"
      />
    </div>
    """
  end

  # -- File panel helpers --

  defp open_file_tab(socket, path, line \\ nil) do
    dir = socket.assigns.session.directory
    {path, read_only} = normalize_file_path(path, dir)

    case Enum.find(socket.assigns.open_files, &(&1.path == path)) do
      nil -> open_new_file_tab(socket, path, line, read_only)
      tab -> switch_to_loaded_tab(socket, tab, path, line)
    end
  end

  # Normalize a file path against the project directory.
  # Absolute paths inside the project are made relative; absolute paths
  # outside the project are kept absolute and marked read-only.
  defp normalize_file_path(path, dir) do
    if String.starts_with?(path, "/") do
      relative = Path.relative_to(path, dir)
      if relative != path, do: {relative, false}, else: {path, true}
    else
      {path, false}
    end
  end

  # File is already open — switch to its tab and update the scroll target.
  defp switch_to_loaded_tab(socket, tab, path, line) do
    block_idx =
      if line && Projects.markdown_file?(path),
        do: MarkdownBlocks.line_to_block_index(tab.content, line),
        else: nil

    socket
    |> assign(:active_file_tab, path)
    |> assign(:file_editing, false)
    |> assign(:editing_block, nil)
    |> assign(:show_file_browser, false)
    |> assign(:scroll_to_line, line)
    |> assign(:scroll_to_block, block_idx)
  end

  # File is not open yet — load it from the (possibly remote) node.
  defp open_new_file_tab(socket, path, line, read_only) do
    dir = socket.assigns.session.directory
    session_node = socket.assigns[:session_node] || node()

    case load_file_content(session_node, dir, path, read_only) do
      {:ok, content} ->
        blocks = if Projects.markdown_file?(path), do: Markdown.split_blocks(content), else: []
        tab = %{path: path, content: content, blocks: blocks, read_only: read_only}
        full_path = if read_only, do: path, else: Path.join(dir, path)
        mtime = remote_file_mtime(session_node, full_path)

        block_idx =
          if line && Projects.markdown_file?(path),
            do: MarkdownBlocks.line_to_block_index(content, line),
            else: nil

        socket
        |> assign(:open_files, socket.assigns.open_files ++ [tab])
        |> assign(:active_file_tab, path)
        |> assign(:file_editing, false)
        |> assign(:editing_block, nil)
        |> assign(:show_file_browser, false)
        |> assign(:file_mtimes, Map.put(socket.assigns.file_mtimes, path, mtime))
        |> assign(:scroll_to_line, line)
        |> assign(:scroll_to_block, block_idx)

      {:error, reason} ->
        put_flash(socket, :error, "Could not open file: #{inspect(reason)}")
    end
  end

  defp load_file_content(session_node, _dir, path, true) do
    Cluster.rpc(session_node, File, :read, [path])
  end

  defp load_file_content(session_node, dir, path, false) do
    Cluster.rpc(session_node, Projects, :load_file, [%Projects.Project{directory: dir}, path])
  end

  defp get_active_tab(socket) do
    Enum.find(socket.assigns.open_files, &(&1.path == socket.assigns.active_file_tab))
  end

  defp refresh_changed_files(socket) do
    dir = socket.assigns.session.directory
    project = %Projects.Project{directory: dir}

    {open_files, mtimes} =
      Enum.map_reduce(socket.assigns.open_files, socket.assigns.file_mtimes, fn tab, mtimes ->
        refresh_tab(tab, mtimes, dir, project)
      end)

    socket
    |> assign(:open_files, open_files)
    |> assign(:file_mtimes, mtimes)
  end

  # Artifact tabs reload via the `"artifact:<id>"` PubSub broadcast
  # (handle_info({:artifact_updated, ...})), not mtime polling — they have
  # no on-disk file to stat.
  defp refresh_tab(%{kind: :artifact} = tab, mtimes, _dir, _project), do: {tab, mtimes}

  # Reloads a single open file tab if its on-disk mtime has changed.
  defp refresh_tab(tab, mtimes, dir, project) do
    full_path = if tab.read_only, do: tab.path, else: Path.join(dir, tab.path)
    current_mtime = file_mtime(full_path)
    stored_mtime = Map.get(mtimes, tab.path)

    if current_mtime != stored_mtime && current_mtime != nil do
      reload_tab(tab, mtimes, project, current_mtime)
    else
      {tab, mtimes}
    end
  end

  defp reload_tab(tab, mtimes, project, current_mtime) do
    result =
      if tab.read_only, do: File.read(tab.path), else: Projects.load_file(project, tab.path)

    case result do
      {:ok, content} ->
        blocks =
          if Projects.markdown_file?(tab.path), do: Markdown.split_blocks(content), else: []

        {%{tab | content: content, blocks: blocks}, Map.put(mtimes, tab.path, current_mtime)}

      {:error, _} ->
        {tab, mtimes}
    end
  end

  defp file_mtime(path) do
    case File.stat(path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  defp remote_file_mtime(target_node, path) do
    case Cluster.rpc(target_node, File, :stat, [path]) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  # -- Heartbeat helpers --

  defp format_interval(seconds) when seconds >= 3600 do
    hours = div(seconds, 3600)
    remaining = rem(seconds, 3600)
    mins = div(remaining, 60)

    if mins == 0, do: "#{hours}h", else: "#{hours}h #{mins}m"
  end

  defp format_interval(seconds) when seconds >= 60 do
    mins = div(seconds, 60)
    secs = rem(seconds, 60)

    if secs == 0, do: "#{mins}m", else: "#{mins}m #{secs}s"
  end

  defp format_interval(seconds), do: "#{seconds}s"

  # -- Commit helpers --

  defp format_commit_date(iso_date) do
    case DateTime.from_iso8601(iso_date) do
      {:ok, dt, _} ->
        Calendar.strftime(dt, "%b %d, %H:%M")

      _ ->
        iso_date
    end
  end

  defp load_session_commits(socket) do
    session_node = socket.assigns[:session_node] || node()

    commits =
      case Cluster.rpc(session_node, Sessions, :list_session_commits, [
             socket.assigns.session.directory,
             socket.assigns.session.id
           ]) do
        list when is_list(list) -> list
        # node_unassigned/node_unavailable (or any other rpc failure) — no
        # commits to show rather than propagating the raw error tuple.
        _ -> []
      end

    assign(socket, :commits, commits)
  end

  # -- Todo helpers --

  defp load_session_todos(socket) do
    assign(socket, :todos, Todos.from_messages(socket.assigns.messages))
  end

  # -- Plan mode helpers --

  defp handle_plan_events(socket, %{"type" => "assistant", "message" => %{"content" => content}})
       when is_list(content) do
    content
    |> Enum.filter(&(is_map(&1) && &1["type"] == "tool_use"))
    |> Enum.reduce(socket, &apply_plan_tool_use(&2, &1))
  end

  defp handle_plan_events(socket, %{"type" => "result"}) do
    case socket.assigns.pending_plan_file do
      nil ->
        socket

      path ->
        session_node = socket.assigns[:session_node] || node()

        socket
        |> assign(:pending_plan_file, nil)
        |> assign(:plan_file_path, path)
        |> assign(:plan_file_original_mtime, remote_file_mtime(session_node, path))
        |> open_file_tab(path)
        |> assign(:file_edit_mode, true)
    end
  end

  defp handle_plan_events(socket, _event), do: socket

  defp apply_plan_tool_use(acc, tool_use) do
    case tool_use["name"] do
      "EnterPlanMode" ->
        assign(acc, :plan_mode, :planning)

      "ExitPlanMode" ->
        assign(acc, :plan_mode, :review)

      "Write" when acc.assigns.plan_mode == :planning ->
        maybe_track_plan_file(acc, tool_use)

      _ ->
        acc
    end
  end

  defp maybe_track_plan_file(acc, tool_use) do
    file_path = get_in(tool_use, ["input", "file_path"]) || ""

    if String.starts_with?(file_path, PlanMode.plans_dir()) do
      assign(acc, :pending_plan_file, file_path)
    else
      acc
    end
  end

  # Extract todos from TodoWrite tool calls in the message stream
  defp handle_todo_events(socket, event) do
    case Todos.from_event(event) do
      nil -> socket
      todos -> assign(socket, :todos, todos)
    end
  end

  defp plan_file_was_edited?(socket) do
    case {socket.assigns.plan_file_path, socket.assigns.plan_file_original_mtime} do
      {nil, _} ->
        false

      {_, nil} ->
        false

      {path, original_mtime} ->
        session_node = socket.assigns[:session_node] || node()
        remote_file_mtime(session_node, path) != original_mtime
    end
  end

  # -- Cluster helpers --

  defp find_session!(id) do
    case HubRPC.get_session(id) do
      nil -> raise Ecto.NoResultsError, queryable: OrcaHub.Sessions.Session
      session -> {Cluster.runner_node_for(session), session}
    end
  end

  defp remote_session?(socket), do: socket.assigns.remote_session
end
