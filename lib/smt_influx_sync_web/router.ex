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

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", SmtInfluxSyncWeb do
    pipe_through :browser

    live "/", StatusLive, :index
    live "/settings", SettingsLive, :index
    live_dashboard "/dashboard", metrics: SmtInfluxSyncWeb.Telemetry
  end

  scope "/", SmtInfluxSyncWeb do
    pipe_through :api

    get "/healthz", HealthController, :index
  end
end
