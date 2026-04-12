defmodule SmtInfluxSyncWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :smt_influx_sync

  @session_options [
    store: :cookie,
    key: "_smt_influx_sync_key",
    signing_salt: "vHk1oO2r",
    same_site: "Lax"
  ]

  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: @session_options]],
    longpoll: [connect_info: [session: @session_options]]

  plug Plug.Static,
    at: "/",
    from: :smt_influx_sync,
    gzip: false,
    only: SmtInfluxSyncWeb.static_paths()

  if code_reloading? do
    plug Phoenix.CodeReloader
  end

  plug Phoenix.LiveDashboard.RequestLogger,
    param_key: "request_logger",
    cookie_key: "request_logger"

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :endpoint]

  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library()

  plug Plug.MethodOverride
  plug Plug.Head
  plug Plug.Session, @session_options
  plug SmtInfluxSyncWeb.Router
end
