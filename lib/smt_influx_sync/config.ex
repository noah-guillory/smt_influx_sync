defmodule SmtInfluxSync.Config do
  @app :smt_influx_sync

  def smt_username, do: Application.fetch_env!(@app, :smt_username)
  def smt_password, do: Application.fetch_env!(@app, :smt_password)
  def smt_esiid, do: Application.fetch_env!(@app, :smt_esiid)
  def smt_meter_number, do: Application.get_env(@app, :smt_meter_number)

  def influx_url, do: Application.fetch_env!(@app, :influx_url)
  def influx_token, do: Application.fetch_env!(@app, :influx_token)
  def influx_org, do: Application.fetch_env!(@app, :influx_org)
  def influx_bucket, do: Application.fetch_env!(@app, :influx_bucket)

  def pending_writes_path,
    do: Application.get_env(@app, :pending_writes_path, "/data/influx_pending_writes.dets")

  def token_path,
    do: Application.get_env(@app, :token_path, "/data/smt_token")

  def last_sync_path(source),
    do: Application.get_env(@app, :data_dir, "/data") <> "/last_sync_#{source}"

  def healthchecks_ping_url, do: Application.get_env(@app, :healthchecks_ping_url)

  def sync_interval_ms, do: Application.get_env(@app, :sync_interval_ms, 1_800_000)
  def poll_interval_ms, do: Application.get_env(@app, :poll_interval_ms, 5_000)
  def poll_max_attempts, do: Application.get_env(@app, :poll_max_attempts, 24)

  def timezone, do: Application.get_env(@app, :timezone, "America/Chicago")
end
