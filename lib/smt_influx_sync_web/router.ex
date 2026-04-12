defmodule SmtInfluxSyncWeb.Router do
  use SmtInfluxSyncWeb, :router

  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {SmtInfluxSyncWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  scope "/", SmtInfluxSyncWeb do
    pipe_through :browser

    live "/", StatusLive, :index
    live_dashboard "/dashboard", metrics: SmtInfluxSyncWeb.Telemetry
  end
end
