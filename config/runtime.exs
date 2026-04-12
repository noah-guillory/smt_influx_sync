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
  data_dir: System.get_env("DATA_DIR", "/tmp/smt_influx_sync_data"),
  pending_writes_path:
    System.get_env("PENDING_WRITES_PATH", "/tmp/smt_influx_sync_data/influx_pending_writes.dets"),
  token_path: System.get_env("TOKEN_PATH", "/tmp/smt_influx_sync_data/smt_token"),
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
  start_workers: config_env() != :test
