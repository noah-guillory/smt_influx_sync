import Config

# Dotenvy.source([".env", System.get_env()])

# if config_env() == :dev do
#   Dotenvy.source([".env", System.get_env()])
# end

config :smt_influx_sync,
  smt_username: System.fetch_env!("SMT_USERNAME"),
  smt_password: System.fetch_env!("SMT_PASSWORD"),
  # Set to your specific ESIID, or "*" to auto-discover from your account
  smt_esiid: System.get_env("SMT_ESIID", "*"),
  smt_meter_number: System.get_env("SMT_METER_NUMBER", "136419480"),
  influx_url: System.fetch_env!("INFLUX_URL"),
  influx_token: System.fetch_env!("INFLUX_TOKEN"),
  influx_org: System.fetch_env!("INFLUX_ORG"),
  influx_bucket: System.fetch_env!("INFLUX_BUCKET"),
  # Default: 30 minutes (SMT rate limit: 2 reads/hour, 24/day)
  sync_interval_ms: String.to_integer(System.get_env("SYNC_INTERVAL_MS", "1800000")),
  poll_interval_ms: 5_000,
  poll_max_attempts: 24,
  smt_request_timeout_ms: String.to_integer(System.get_env("SMT_REQUEST_TIMEOUT_MS", "120000")),
  # Base directory for all persisted state files.
  # Mount this as a Docker volume to survive container restarts.
  data_dir: System.get_env("DATA_DIR", "/data"),
  pending_writes_path: System.get_env("PENDING_WRITES_PATH", "/data/influx_pending_writes.dets"),
  token_path: System.get_env("TOKEN_PATH", "/data/smt_token"),
  healthchecks_ping_url: System.get_env("HEALTHCHECKS_PING_URL"),
  timezone: System.get_env("TZ", "America/Chicago")
