defmodule OrcaHubWeb.Router do
  use OrcaHubWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {OrcaHubWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :api_authed do
    plug :accepts, ["json"]
    plug OrcaHubWeb.Plugs.ApiAuth
  end

  # Deliberately minimal: no session/CSRF/layout machinery, no CSP — see
  # OrcaHubWeb.ArtifactController moduledoc. Just enough to get query params
  # (the `?v=` cache-buster) parsed.
  pipeline :artifact_raw do
    plug :fetch_query_params
  end

  scope "/", OrcaHubWeb do
    pipe_through :browser

    live_session :default, on_mount: [{OrcaHubWeb.NodeFilter, :default}] do
      live "/", DashboardLive, :index

      live "/projects", ProjectLive.Index, :index
      live "/projects/new", ProjectLive.Index, :new
      live "/projects/:id", ProjectLive.Show, :show
      live "/projects/:id/edit", ProjectLive.Show, :edit

      live "/triggers", TriggerLive.Index, :index
      live "/triggers/new", TriggerLive.Index, :new
      live "/triggers/:id/edit", TriggerLive.Index, :edit

      live "/skills", SkillLive.Index, :index
      live "/skills/new", SkillLive.Index, :new
      live "/skills/:id/edit", SkillLive.Index, :edit

      live "/issues", IssueLive.Index, :index
      live "/issues/:id", IssueLive.Show, :show

      live "/queue", QueueLive, :index
      live "/usage", UsageLive, :index

      live "/nodes", NodeLive.Index, :index
      live "/nodes/:id", NodeLive.Show, :show

      live "/terminals", TerminalLive.Index, :index
      live "/terminals/new", TerminalLive.Index, :new
      live "/terminals/:id", TerminalLive.Show, :show

      live "/sessions", SessionLive.Index, :index
      live "/sessions/new", SessionLive.Index, :new
      live "/sessions/:id", SessionLive.Show, :show

      live "/artifacts/:id", ArtifactLive.Show, :show

      live "/settings", SettingsLive.Index, :index
      live "/settings/upstream/new", SettingsLive.Index, :new
      live "/settings/upstream/:id/edit", SettingsLive.Index, :edit
    end
  end

  scope "/artifacts", OrcaHubWeb do
    pipe_through :artifact_raw
    get "/:id/raw", ArtifactController, :raw
  end

  scope "/api", OrcaHubWeb do
    pipe_through :api
    post "/tts", TTSController, :create
    post "/webhooks/:secret", WebhookController, :create
  end

  scope "/api/v1", OrcaHubWeb do
    pipe_through :api_authed
    post "/runs", ApiRunController, :create
    get "/runs/:id", ApiRunController, :show
  end

  # MCP Streamable HTTP endpoint
  forward "/mcp", OrcaHub.MCP.Plug

  # Enable LiveDashboard and Swoosh mailbox preview in development
  if Application.compile_env(:orca_hub, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: OrcaHubWeb.Telemetry
      forward "/mailbox", Plug.Swoosh.MailboxPreview
    end
  end
end
