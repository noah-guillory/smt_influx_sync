import Config

# Dotenvy.source([".env", System.get_env()])

# if config_env() == :dev do
#   Dotenvy.source([".env", System.get_env()])
# end

config :smt_influx_sync,
  smt_username: System.get_env("SMT_USERNAME", "dummy"),
  smt_password: System.get_env("SMT_PASSWORD", "dummy"),
  # Set to your specific ESIID, or "*" to auto-discover from your account
  smt_esiid: System.get_env("SMT_ESIID", "*"),
  smt_meter_number: System.get_env("SMT_METER_NUMBER", "136419480"),
  influx_url: System.get_env("INFLUX_URL", "http://localhost:8086"),
  influx_token: System.get_env("INFLUX_TOKEN", "dummy"),
  influx_org: System.get_env("INFLUX_ORG", "dummy"),
  influx_bucket: System.get_env("INFLUX_BUCKET", "dummy"),
  poll_interval_ms: 5_000,
  poll_max_attempts: 24,
  smt_request_timeout_ms: String.to_integer(System.get_env("SMT_REQUEST_TIMEOUT_MS", "120000")),
  # Base directory for all persisted state files.
  # Mount this as a Docker volume to survive container restarts.
  healthchecks_ping_url: System.get_env("HEALTHCHECKS_PING_URL"),
  ynab_healthchecks_ping_url: System.get_env("YNAB_HEALTHCHECKS_PING_URL"),
  timezone: System.get_env("TZ", "America/Chicago"),
  ynab_access_token: System.get_env("YNAB_ACCESS_TOKEN", "dummy"),
  ynab_budget_id: System.get_env("YNAB_BUDGET_ID", "dummy"),
  ynab_category_id: System.get_env("YNAB_CATEGORY_ID", "dummy"),
  kwh_rate: System.get_env("KWH_RATE", "0.1") |> String.to_float(),
  ynab_sync_interval_ms:
    String.to_integer(System.get_env("YNAB_SYNC_INTERVAL_MS", "#{86_400_000 * 30}")),
  odr_sync_interval_ms:
    String.to_integer(System.get_env("ODR_SYNC_INTERVAL_MS", "3600000")),
  interval_sync_interval_ms:
    String.to_integer(System.get_env("INTERVAL_SYNC_INTERVAL_MS", "3600000")),
  daily_sync_interval_ms:
    String.to_integer(System.get_env("DAILY_SYNC_INTERVAL_MS", "86400000")),
  monthly_sync_interval_ms:
    String.to_integer(System.get_env("MONTHLY_SYNC_INTERVAL_MS", "86400000")),
  initial_lookback_days:
    String.to_integer(System.get_env("INITIAL_LOOKBACK_DAYS", "730")),
  start_workers: config_env() != :test

if config_env() != :test do
  config :smt_influx_sync,
    data_dir: System.get_env("DATA_DIR", "/tmp/smt_influx_sync_data"),
    pending_writes_path:
      System.get_env("PENDING_WRITES_PATH", "/tmp/smt_influx_sync_data/influx_pending_writes.dets"),
    token_path: System.get_env("TOKEN_PATH", "/tmp/smt_influx_sync_data/smt_token")
end

# Ecto Repo configuration
if config_env() != :test do
  data_dir = System.get_env("DATA_DIR", "/tmp/smt_influx_sync_data")
  database_path = Path.join(data_dir, "smt_influx_sync.db")

  config :smt_influx_sync, SmtInfluxSync.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5"),
    stacktrace: true,
    show_sensitive_data_on_connection_error: true
end

# Phoenix Endpoint configuration
if config_env() != :test do
  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  config :smt_influx_sync, SmtInfluxSyncWeb.Endpoint,
    url: [host: host, port: port, scheme: "http"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0},
      port: port
    ],
    secret_key_base:
      System.get_env("SECRET_KEY_BASE") ||
        "pW56m3P8C4eU9B/qD5gR6v7X9Y+Z/W8kL9M0N1P2Q3R4S5T6U7V8W9X0Y1Z2A3B4",
    check_origin: [
      "//#{host}",
      "//localhost",
      "//127.0.0.1"
    ]
end
