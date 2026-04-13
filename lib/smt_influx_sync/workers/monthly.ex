defmodule SmtInfluxSync.Workers.Monthly do
  @moduledoc """
  Oban worker for historical monthly usage data sync.
  """
  use Oban.Worker, queue: :default, max_attempts: 3
  require Logger

  alias SmtInfluxSync.{Config, SMTClient}
  alias SmtInfluxSync.SMT.Session
  alias SmtInfluxSync.Workers.Helper

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Session.get_credentials() do
      {:ok, credentials} ->
        Logger.metadata(worker: :monthly, esiid: credentials.esiid)
        Logger.info("[monthly] Starting sync")
        sync_log = SmtInfluxSync.SyncMetadata.log_start("monthly")
        started_at = System.monotonic_time(:millisecond)

        case do_sync(credentials) do
          :ok ->
            elapsed = System.monotonic_time(:millisecond) - started_at
            Logger.info("[monthly] Sync completed successfully in #{elapsed}ms")
            SmtInfluxSync.SyncMetadata.log_success(sync_log, "Sync completed in #{elapsed}ms")
            schedule_next()
            :ok

          {:error, :unauthorized} ->
            Session.refresh_token()
            SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Unauthorized, token refreshed")
            {:error, :unauthorized}

          {:error, reason} ->
            Logger.error("[monthly] Sync failed: #{inspect(reason)}")
            SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Sync failed: #{inspect(reason)}")
            schedule_next()
            {:error, reason}
        end

      {:error, :not_ready} ->
        Logger.debug("[monthly] Session not ready, retrying in 1 minute")
        {:error, :not_ready}
    end
  end

  def schedule_next do
    {h, m} = Config.parse_time_string(Config.monthly_sync_time())
    ms = Helper.ms_until_next_time(h, m)
    
    %{}
    |> __MODULE__.new(scheduled_at: DateTime.add(DateTime.utc_now(), ms, :millisecond))
    |> Oban.insert!()
  end

  # --- Private ---

  defp do_sync(credentials) do
    today = Date.utc_today()
    tags = %{esiid: credentials.esiid, meter_number: credentials.meter_number, source: "monthly"}
    start_date = Helper.last_sync_start("monthly", today)

    Logger.info("[monthly] Fetching #{SMTClient.format_date(start_date)}–#{SMTClient.format_date(today)}")

    case SMTClient.get_monthly_data(credentials.token, credentials.esiid, start_date, today) do
      {:ok, records} ->
        Logger.info("[monthly] Fetched #{length(records)} records")
        if Helper.write_records("electricity_monthly", tags, records, &Helper.parse_monthly_record/1) do
          Helper.save_last_sync("monthly", today)
          :ok
        else
          {:error, :influx_write_failed}
        end

      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end
end
