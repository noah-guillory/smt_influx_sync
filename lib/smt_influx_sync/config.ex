defmodule SmtInfluxSync.Config do
  @app :smt_influx_sync

  def smt_username, do: Application.fetch_env!(@app, :smt_username)
  def smt_password, do: Application.fetch_env!(@app, :smt_password)
  def smt_esiid, do: Application.fetch_env!(@app, :smt_esiid)
  def smt_meter_number, do: Application.get_env(@app, :smt_meter_number)

  def smt_auth_url,
    do:
      Application.get_env(
        @app,
        :smt_auth_url,
        "https://www.smartmetertexas.com/commonapi/user/authenticate"
      )

  def smt_base_url,
    do: Application.get_env(@app, :smt_base_url, "https://www.smartmetertexas.com/api")

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

  def odr_daily_count_path,
    do: Application.get_env(@app, :data_dir, "/data") <> "/odr_daily_count"

  def odr_daily_limit, do: Application.get_env(@app, :odr_daily_limit, 24)

  def healthchecks_ping_url, do: Application.get_env(@app, :healthchecks_ping_url)
  def ynab_healthchecks_ping_url, do: Application.get_env(@app, :ynab_healthchecks_ping_url)

  def ynab_access_token, do: Application.fetch_env!(@app, :ynab_access_token)
  def ynab_budget_id, do: Application.fetch_env!(@app, :ynab_budget_id)
  def ynab_category_id, do: Application.fetch_env!(@app, :ynab_category_id)
  def kwh_rate, do: Application.fetch_env!(@app, :kwh_rate)

  def ynab_base_url, do: Application.get_env(@app, :ynab_base_url, "https://api.ynab.com")

  def ynab_sync_interval_ms,
    do: Application.get_env(@app, :ynab_sync_interval_ms, 86_400_000 * 30)

  def smt_request_timeout_ms, do: Application.get_env(@app, :smt_request_timeout_ms, 120_000)

  def odr_sync_interval_ms, do: Application.get_env(@app, :odr_sync_interval_ms, 3_600_000)
  def interval_sync_interval_ms, do: Application.get_env(@app, :interval_sync_interval_ms, 3_600_000)
  def daily_sync_interval_ms, do: Application.get_env(@app, :daily_sync_interval_ms, 86_400_000)
  def monthly_sync_interval_ms, do: Application.get_env(@app, :monthly_sync_interval_ms, 86_400_000)

  def poll_interval_ms, do: Application.get_env(@app, :poll_interval_ms, 5_000)
  def poll_max_attempts, do: Application.get_env(@app, :poll_max_attempts, 24)

  def timezone, do: Application.get_env(@app, :timezone, "America/Chicago")

  def initial_lookback_days, do: Application.get_env(@app, :initial_lookback_days, 730)
end
