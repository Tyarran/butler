defmodule ButlerWeb.Router do
  use ButlerWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {ButlerWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  # Job API: loopback + Host + Origin, then the Bearer token, then JSON.
  pipeline :api do
    plug ButlerWeb.Plugs.LoopbackGuard
    plug ButlerWeb.Plugs.APIAuth
    plug :accepts, ["json"]
  end

  # MCP proxy: no session, no CSRF, no authentication. Loopback only.
  pipeline :mcp do
    plug ButlerWeb.Plugs.LoopbackGuard
  end

  scope "/api/v1", ButlerWeb do
    pipe_through :api

    post "/jobs", JobController, :create
    get "/jobs/:id", JobController, :show
    get "/health", HealthController, :show
  end

  scope "/mcp", ButlerWeb do
    pipe_through :mcp

    post "/:backend", MCPController, :post
    delete "/:backend", MCPController, :delete
    get "/:backend", MCPController, :stream
  end

  scope "/", ButlerWeb do
    pipe_through :browser

    get "/", PageController, :home

    live "/daemon", DaemonLive
    live "/jobs", JobsLive
    live "/jobs/:id", JobLive
    live "/launch", LaunchLive
    live "/maintenance", MaintenanceLive
    live "/mcp", MCPLive
    live "/palace", PalaceLive
    live "/worker", WorkerLive
  end

  # Enable LiveDashboard in development
  if Application.compile_env(:butler, :dev_routes) do
    # If you want to use the LiveDashboard in production, you should put
    # it behind authentication and allow only admins to access it.
    # If your application does not have an admins-only section yet,
    # you can use Plug.BasicAuth to set up some basic authentication
    # as long as you are also using SSL (which you should anyway).
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through :browser

      live_dashboard "/dashboard", metrics: ButlerWeb.Telemetry
    end
  end
end
