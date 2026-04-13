defmodule SmtInfluxSync.Workers.ODR do
  @moduledoc """
  Worker for On-Demand Read (ODR) sync.
  """
  use GenServer
  require Logger

  alias SmtInfluxSync.{Config, SMTClient, InfluxWriter}
  alias SmtInfluxSync.SMT.Session
  alias SmtInfluxSync.Workers.Helper

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    Logger.info("[odr] Starting ODR worker")
    
    if SmtInfluxSync.SyncMetadata.needs_initial_sync?("odr", 1) do
      schedule_sync(0)
    else
      schedule_sync()
    end

    {:ok, %{}}
  end

  @impl true
  def handle_info(:sync, state) do
    case Session.get_credentials() do
      {:ok, credentials} ->
        Logger.metadata(worker: :odr, esiid: credentials.esiid)
        Logger.info("Starting sync")
        sync_log = SmtInfluxSync.SyncMetadata.log_start("odr")
        started_at = System.monotonic_time(:millisecond)

        case do_sync(credentials) do
          :ok ->
            elapsed = System.monotonic_time(:millisecond) - started_at
            Logger.info("Sync completed successfully in #{elapsed}ms")
            Helper.save_last_sync_now("odr")
            SmtInfluxSync.SyncMetadata.log_success(sync_log, "Sync completed in #{elapsed}ms")
            Helper.ping_healthcheck(:success, Config.healthchecks_ping_url())
            schedule_sync()

          {:error, :rate_limited} ->
            Logger.warning("Rate limited, retrying later")
            SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Rate limited")
            schedule_sync()

          {:error, :daily_limit_reached} ->
            Logger.warning("Daily limit reached, retrying tomorrow")
            SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Daily limit reached")
            # Schedule for roughly next day or just stick to interval
            schedule_sync()

          {:error, reason} ->
            Logger.error("Sync failed: #{inspect(reason)}")
            SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Sync failed: #{inspect(reason)}")
            Helper.ping_healthcheck(:fail, Config.healthchecks_ping_url())
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
    case request_and_read(credentials) do
      {:ok, reading} ->
        timestamp =
          case SMTClient.parse_odr_date(reading.date) do
            {:ok, unix} -> unix
            :error -> DateTime.to_unix(DateTime.utc_now())
          end

        InfluxWriter.write(
          "electricity_usage",
          %{esiid: credentials.esiid, meter_number: credentials.meter_number, source: "odr"},
          %{value: reading.value, usage: reading.usage},
          timestamp
        )

      {:error, :unauthorized} ->
        Session.refresh_token()
        {:error, :unauthorized}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp request_and_read(credentials) do
    case check_recent_read(credentials) do
      {:reuse, reading} ->
        Logger.info("[odr] Reusing recent read from #{reading.date}")
        {:ok, reading}

      :stale ->
        request_odr_and_read(credentials)
    end
  end

  defp check_recent_read(credentials) do
    case SMTClient.get_latest_read(credentials.token, credentials.esiid) do
      {:ok, :no_data} -> :stale
      {:ok, reading} ->
        # Use 1 hour as threshold for reusing recent reads
        threshold_s = System.os_time(:second) - 3600
        case SMTClient.parse_odr_date(reading.date) do
          {:ok, read_unix} when read_unix >= threshold_s -> {:reuse, reading}
          _ -> :stale
        end
      {:error, _} -> :stale
    end
  end

  defp request_odr_and_read(credentials) do
    limit = Config.odr_daily_limit()
    count = odr_daily_count()

    if count >= limit do
      {:error, :daily_limit_reached}
    else
      execute_odr_request(credentials)
    end
  end

  defp execute_odr_request(credentials) do
    case SMTClient.request_odr(credentials.token, credentials.esiid, credentials.meter_number) do
      :ok ->
        increment_odr_daily_count()
        SMTClient.poll_odr(credentials.token, credentials.esiid)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp odr_daily_count do
    today = Date.to_iso8601(Date.utc_today())
    path = Config.odr_daily_count_path()

    case File.read(path) do
      {:ok, contents} ->
        case String.split(String.trim(contents), "\n") do
          [^today, count_str] -> String.to_integer(count_str)
          _ -> 0
        end
      {:error, _} -> 0
    end
  end

  defp increment_odr_daily_count do
    count = odr_daily_count() + 1
    today = Date.to_iso8601(Date.utc_today())
    path = Config.odr_daily_count_path()
    path |> Path.dirname() |> File.mkdir_p!()
    File.write(path, "#{today}\n#{count}")
  end

  defp schedule_sync(interval \\ nil) do
    ms =
      if interval do
        interval
      else
        {h, m} = Config.parse_time_string(Config.odr_sync_time())
        Helper.ms_until_next_time(h, m)
      end

    Process.send_after(self(), :sync, ms)
  end
end
