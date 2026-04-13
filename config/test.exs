import Config

config :smt_influx_sync, SmtInfluxSync.Repo,
  database: "/tmp/smt_influx_sync_test.db",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 10

config :smt_influx_sync,
  run_migrations: true,
  start_workers: false,
  oban_enabled: false,
  data_dir: "/tmp/smt_influx_sync_test_data"
