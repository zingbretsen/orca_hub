defmodule OrcaHubWeb.CommandPaletteLive do
  use OrcaHubWeb, :live_component

  alias OrcaHub.{Sessions, Projects, Issues, Cluster}

  @nav_commands [
    %{name: "Dashboard", path: "/", category: "Navigation", icon: "hero-home"},
    %{name: "Queue", path: "/queue", category: "Navigation", icon: "hero-queue-list"},
    %{name: "Projects", path: "/projects", category: "Navigation", icon: "hero-folder"},
    %{name: "Issues", path: "/issues", category: "Navigation", icon: "hero-bug-ant"},
    %{name: "Triggers", path: "/triggers", category: "Navigation", icon: "hero-bolt"},
    %{name: "Sessions", path: "/sessions", category: "Navigation", icon: "hero-chat-bubble-left-right"},
    %{name: "Usage", path: "/usage", category: "Navigation", icon: "hero-chart-bar"}
  ]

  @action_commands [
    %{name: "New Session", path: "/sessions/new", category: "Actions", icon: "hero-plus"},
    %{name: "New Project", path: "/projects/new", category: "Actions", icon: "hero-plus"},
    %{name: "New Issue", path: "/issues/new", category: "Actions", icon: "hero-plus"},
    %{name: "New Trigger", path: "/triggers/new", category: "Actions", icon: "hero-plus"}
  ]

  @impl true
  def mount(socket) do
    {:ok,
     assign(socket,
       open: false,
       query: "",
       results: [],
       selected_index: 0,
       phase: :search,
       selected_project: nil,
       include_archived: false
     )}
  end

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, id: assigns.id)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id={@id} phx-hook="CommandPalette" phx-target={@myself}>
      <div
        :if={@open}
        class="fixed inset-0 z-[70] flex items-start justify-center pt-[15vh]"
      >
        <div class="fixed inset-0 bg-black/50" phx-click="close" phx-target={@myself} />

        <div class="relative w-full max-w-lg bg-base-100 rounded-xl shadow-2xl border border-base-300 overflow-hidden">
          <%!-- Search input --%>
          <div class="flex items-center gap-3 px-4 py-3 border-b border-base-300">
            <.icon name={if @phase == :project_actions, do: "hero-folder", else: "hero-magnifying-glass"} class="size-5 opacity-50 shrink-0" />
            <div :if={@phase == :project_actions} class="badge badge-sm badge-primary shrink-0">
              {@selected_project.name}
            </div>
            <input
              id="command-palette-input"
              type="text"
              value={@query}
              placeholder={placeholder(@phase)}
              class="flex-1 bg-transparent border-none outline-none focus:ring-0 text-base p-0"
              phx-keyup="search"
              phx-target={@myself}
              autocomplete="off"
              phx-debounce="150"
            />
            <div :if={@phase == :project_actions}>
              <kbd class="kbd kbd-xs opacity-50">Bksp</kbd>
              <span class="text-xs opacity-50">back</span>
            </div>
            <button
              :if={@phase == :search}
              type="button"
              class={"btn btn-xs gap-1 #{if @include_archived, do: "btn-primary", else: "btn-ghost opacity-50"}"}
              phx-click="toggle-archived"
              phx-target={@myself}
              title="Include archived sessions"
            >
              <.icon name="hero-archive-box-mini" class="size-3.5" />
              <span class="hidden sm:inline">Archived</span>
            </button>
          </div>

          <%!-- Results --%>
          <div class="max-h-80 overflow-y-auto p-2" id="command-palette-results">
            <%= if @results == [] do %>
              <div class="px-3 py-6 text-center text-sm opacity-50">No results found</div>
            <% else %>
              <% grouped = group_results(@results) %>
              <%= for {category, items} <- grouped do %>
                <div class="px-3 pt-2 pb-1 text-xs font-semibold uppercase tracking-wider opacity-40">
                  {category}
                </div>
                <%= for {item, idx} <- items do %>
                  <button
                    class={"flex items-center gap-3 w-full px-3 py-2 rounded-lg text-left text-sm cursor-pointer #{if idx == @selected_index, do: "bg-primary/10 text-primary", else: "hover:bg-base-200"}"}
                    phx-click="select"
                    phx-value-index={idx}
                    phx-target={@myself}
                    id={"command-palette-item-#{idx}"}
                  >
                    <.icon name={item.icon} class="size-4 shrink-0 opacity-60" />
                    <div class="flex-1 min-w-0">
                      <div class="truncate">{item.name}</div>
                      <div :if={item[:subtitle]} class="text-xs opacity-50 truncate">{item.subtitle}</div>
                    </div>
                    <div :if={item[:hint]} class="text-xs opacity-40 shrink-0">{item.hint}</div>
                    <.icon :if={item[:drillable]} name="hero-chevron-right-mini" class="size-4 opacity-30 shrink-0" />
                  </button>
                <% end %>
              <% end %>
            <% end %>
          </div>

          <%!-- Footer hints --%>
          <div class="flex items-center gap-4 px-4 py-2 border-t border-base-300 text-xs opacity-40">
            <span><kbd class="kbd kbd-xs">↑↓</kbd> navigate</span>
            <span><kbd class="kbd kbd-xs">↵</kbd> select</span>
            <span><kbd class="kbd kbd-xs">esc</kbd> close</span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  @impl true
  def handle_event("toggle", _params, socket) do
    if socket.assigns.open do
      {:noreply, close_palette(socket)}
    else
      {:noreply, open_palette(socket)}
    end
  end

  def handle_event("close", _params, socket) do
    {:noreply, close_palette(socket)}
  end

  def handle_event("toggle-archived", _params, socket) do
    include_archived = !socket.assigns.include_archived
    results = build_results(socket.assigns.query, socket.assigns.phase, socket.assigns.selected_project, include_archived: include_archived)
    {:noreply, assign(socket, include_archived: include_archived, results: results, selected_index: 0)}
  end

  def handle_event("search", %{"value" => query}, socket) do
    if query == socket.assigns.query do
      {:noreply, socket}
    else
      results = build_results(query, socket.assigns.phase, socket.assigns.selected_project, include_archived: socket.assigns.include_archived)
      {:noreply, assign(socket, query: query, results: results, selected_index: 0)}
    end
  end

  def handle_event("back", _params, socket) do
    if socket.assigns.phase == :project_actions do
      results = build_results("", :search, nil)

      {:noreply,
       socket
       |> assign(phase: :search, selected_project: nil, query: "", results: results, selected_index: 0)
       |> push_event("clear-command-palette-input", %{})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("move", %{"direction" => direction}, socket) do
    max_index = length(socket.assigns.results) - 1

    new_index =
      case direction do
        "down" -> min(socket.assigns.selected_index + 1, max_index)
        "up" -> max(socket.assigns.selected_index - 1, 0)
      end

    {:noreply, assign(socket, selected_index: new_index)}
  end

  def handle_event("go", _params, socket) do
    select_item(socket, socket.assigns.selected_index)
  end

  def handle_event("select", %{"index" => index}, socket) do
    select_item(socket, String.to_integer(index))
  end

  defp select_item(socket, index) do
    case Enum.at(socket.assigns.results, index) do
      %{drillable: true, project: project} ->
        results = build_results("", :project_actions, project)

        {:noreply,
         socket
         |> assign(
           phase: :project_actions,
           selected_project: project,
           query: "",
           results: results,
           selected_index: 0
         )
         |> push_event("clear-command-palette-input", %{})}

      %{action: :create_session, project: project} ->
        case Sessions.create_session(%{"project_id" => project.id, "directory" => project.directory}) do
          {:ok, session} ->
            {:ok, _} = OrcaHub.SessionSupervisor.start_session(session.id)
            {:noreply, socket |> close_palette() |> push_navigate(to: "/sessions/#{session.id}")}

          {:error, _} ->
            {:noreply, socket |> close_palette() |> put_flash(:error, "Failed to create session")}
        end

      %{path: path} when is_binary(path) ->
        {:noreply, socket |> close_palette() |> push_navigate(to: path)}

      _ ->
        {:noreply, socket}
    end
  end

  defp open_palette(socket) do
    results = build_results("", :search, nil)

    socket
    |> assign(open: true, query: "", results: results, selected_index: 0, phase: :search, selected_project: nil)
    |> push_event("focus-command-palette", %{})
  end

  defp close_palette(socket) do
    assign(socket, open: false, query: "", results: [], selected_index: 0, phase: :search, selected_project: nil)
  end

  defp build_results(query, phase, project, opts \\ [])

  defp build_results(query, :search, _project, opts) do
    query = String.trim(query)
    static = filter_commands(@nav_commands ++ @action_commands, query)

    if query == "" do
      static
    else
      projects =
        Projects.search(query)
        |> Enum.map(fn p ->
          %{name: p.name, subtitle: p.directory, category: "Projects", icon: "hero-folder", drillable: true, project: p}
        end)

      sessions =
        Cluster.search(query, opts)
        |> Enum.map(fn {_node, s} ->
          %{
            name: s.title || Path.basename(s.directory),
            subtitle: if(s.project, do: s.project.name, else: s.directory),
            path: "/sessions/#{s.id}",
            category: "Sessions",
            icon: "hero-chat-bubble-left-right",
            hint: if(s.archived_at, do: "archived")
          }
        end)

      issues =
        Issues.search(query)
        |> Enum.map(fn i ->
          %{
            name: i.title,
            subtitle: if(i.project, do: i.project.name),
            path: "/issues/#{i.id}",
            category: "Issues",
            icon: "hero-bug-ant"
          }
        end)

      static ++ projects ++ sessions ++ issues
    end
  end

  defp build_results(query, :project_actions, project, _opts) do
    commands = [
      %{name: "Go to Project", path: "/projects/#{project.id}", category: "Navigate", icon: "hero-arrow-right", hint: "view"},
      %{name: "New Session", action: :create_session, project: project, category: "Actions", icon: "hero-chat-bubble-left-right", hint: "launch"},
      %{name: "New Issue", path: "/issues/new?project_id=#{project.id}", category: "Actions", icon: "hero-bug-ant", hint: "create"},
      %{name: "New Trigger", path: "/triggers/new?project_id=#{project.id}", category: "Actions", icon: "hero-bolt", hint: "create"}
    ]

    filter_commands(commands, query)
  end

  defp filter_commands(commands, "") do
    commands
  end

  defp filter_commands(commands, query) do
    query_down = String.downcase(query)

    Enum.filter(commands, fn cmd ->
      String.contains?(String.downcase(cmd.name), query_down)
    end)
  end

  defp group_results(results) do
    results
    |> Enum.with_index()
    |> Enum.group_by(fn {item, _idx} -> item.category end)
    |> Enum.sort_by(fn {category, _} ->
      case category do
        "Navigation" -> 0
        "Navigate" -> 0
        "Actions" -> 1
        "Projects" -> 2
        "Sessions" -> 3
        "Issues" -> 4
        _ -> 5
      end
    end)
  end

  defp placeholder(:search), do: "Search commands, projects, sessions..."
  defp placeholder(:project_actions), do: "Select an action..."
end
