defmodule SmtInfluxSync.Workers.Daily do
  @moduledoc """
  Oban worker for historical daily usage data sync.
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
        Logger.metadata(worker: :daily, esiid: credentials.esiid)
        Logger.info("[daily] Starting sync")
        sync_log = SmtInfluxSync.SyncMetadata.log_start("daily")
        started_at = System.monotonic_time(:millisecond)

        case do_sync(credentials) do
          :ok ->
            elapsed = System.monotonic_time(:millisecond) - started_at
            Logger.info("[daily] Sync completed successfully in #{elapsed}ms")
            SmtInfluxSync.SyncMetadata.log_success(sync_log, "Sync completed in #{elapsed}ms")
            schedule_next()
            :ok

          {:error, :unauthorized} ->
            Session.refresh_token()
            SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Unauthorized, token refreshed")
            # Return error to trigger Oban retry
            {:error, :unauthorized}

          {:error, reason} ->
            Logger.error("[daily] Sync failed: #{inspect(reason)}")
            SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Sync failed: #{inspect(reason)}")
            schedule_next()
            {:error, reason}
        end

      {:error, :not_ready} ->
        Logger.debug("[daily] Session not ready, retrying in 1 minute")
        {:error, :not_ready}
    end
  end

  def schedule_next do
    {h, m} = Config.parse_time_string(Config.daily_sync_time())
    ms = Helper.ms_until_next_time(h, m)
    
    %{}
    |> __MODULE__.new(scheduled_at: DateTime.add(DateTime.utc_now(), ms, :millisecond))
    |> Oban.insert!()
  end

  # --- Private ---

  defp do_sync(credentials) do
    today = Date.utc_today()
    tags = %{esiid: credentials.esiid, meter_number: credentials.meter_number, source: "daily"}
    start_date = Helper.last_sync_start("daily", today)

    Logger.info("[daily] Fetching #{SMTClient.format_date(start_date)}–#{SMTClient.format_date(today)}")

    case SMTClient.get_daily_data(credentials.token, credentials.esiid, start_date, today) do
      {:ok, records} ->
        Logger.info("[daily] Fetched #{length(records)} records")
        if Helper.write_records("electricity_daily", tags, records, &Helper.parse_daily_record/1) do
          Helper.save_last_sync("daily", today)
          :ok
        else
          {:error, :influx_write_failed}
        end

      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end
end
