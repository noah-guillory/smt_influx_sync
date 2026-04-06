defmodule SmtInfluxSync.Config do
  @app :smt_influx_sync

  def smt_username, do: Application.fetch_env!(@app, :smt_username)
  def smt_password, do: Application.fetch_env!(@app, :smt_password)
  def smt_esiid, do: Application.fetch_env!(@app, :smt_esiid)

  def influx_url, do: Application.fetch_env!(@app, :influx_url)
  def influx_token, do: Application.fetch_env!(@app, :influx_token)
  def influx_org, do: Application.fetch_env!(@app, :influx_org)
  def influx_bucket, do: Application.fetch_env!(@app, :influx_bucket)

  def sync_interval_ms, do: Application.get_env(@app, :sync_interval_ms, 1_800_000)
  def poll_interval_ms, do: Application.get_env(@app, :poll_interval_ms, 5_000)
  def poll_max_attempts, do: Application.get_env(@app, :poll_max_attempts, 24)
end
