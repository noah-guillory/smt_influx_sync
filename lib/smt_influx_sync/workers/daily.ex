defmodule SmtInfluxSync.Workers.Daily do
  @moduledoc """
  Worker for historical daily usage data sync.
  """
  use GenServer
  require Logger

  alias SmtInfluxSync.{Config, SMTClient}
  alias SmtInfluxSync.SMT.Session
  alias SmtInfluxSync.Workers.Helper

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    Logger.info("[daily] Starting daily sync worker")
    schedule_sync(0)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sync, state) do
    case Session.get_credentials() do
      {:ok, credentials} ->
        Logger.metadata(worker: :daily, esiid: credentials.esiid)
        Logger.info("Starting sync")
        sync_log = SmtInfluxSync.SyncMetadata.log_start("daily")
        started_at = System.monotonic_time(:millisecond)

        case do_sync(credentials) do
          :ok ->
            elapsed = System.monotonic_time(:millisecond) - started_at
            Logger.info("Sync completed successfully in #{elapsed}ms")
            SmtInfluxSync.SyncMetadata.log_success(sync_log, "Sync completed in #{elapsed}ms")
            schedule_sync()

          {:error, :unauthorized} ->
            Session.refresh_token()
            schedule_sync(5000)

          {:error, reason} ->
            Logger.error("Sync failed: #{inspect(reason)}")
            SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Sync failed: #{inspect(reason)}")
            schedule_sync()
        end

      {:error, :not_ready} ->
        Logger.debug("Session not ready, retrying in 10s")
        schedule_sync(10_000)
    end

    {:noreply, state}
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

  defp schedule_sync(interval \\ nil) do
    ms = interval || Config.daily_sync_interval_ms()
    Process.send_after(self(), :sync, ms)
  end
end
