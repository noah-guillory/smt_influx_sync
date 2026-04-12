defmodule SmtInfluxSync.Workers.Monthly do
  @moduledoc """
  Worker for historical monthly usage data sync.
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
    Logger.info("[monthly] Starting monthly sync worker")
    schedule_sync(0)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sync, state) do
    case Session.get_credentials() do
      {:ok, credentials} ->
        Logger.info("[monthly] Starting sync")
        started_at = System.monotonic_time(:millisecond)

        case do_sync(credentials) do
          :ok ->
            elapsed = System.monotonic_time(:millisecond) - started_at
            Logger.info("[monthly] Sync completed successfully in #{elapsed}ms")
            schedule_sync()

          {:error, :unauthorized} ->
            Session.refresh_token()
            schedule_sync(5000)

          {:error, reason} ->
            Logger.error("[monthly] Sync failed: #{inspect(reason)}")
            schedule_sync()
        end

      {:error, :not_ready} ->
        Logger.debug("[monthly] Session not ready, retrying in 10s")
        schedule_sync(10_000)
    end

    {:noreply, state}
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

  defp schedule_sync(interval \\ nil) do
    ms = interval || Config.monthly_sync_interval_ms()
    Process.send_after(self(), :sync, ms)
  end
end
