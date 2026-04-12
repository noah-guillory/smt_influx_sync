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
    schedule_sync(0)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sync, state) do
    case Session.get_credentials() do
      {:ok, credentials} ->
        Logger.info("[odr] Starting sync")
        Helper.ping_healthcheck(:start, Config.healthchecks_ping_url())
        started_at = System.monotonic_time(:millisecond)

        case do_sync(credentials) do
          :ok ->
            elapsed = System.monotonic_time(:millisecond) - started_at
            Logger.info("[odr] Sync completed successfully in #{elapsed}ms")
            Helper.ping_healthcheck(:success, Config.healthchecks_ping_url())
            schedule_sync()

          {:error, :rate_limited} ->
            Logger.warning("[odr] Rate limited, retrying later")
            schedule_sync()

          {:error, :daily_limit_reached} ->
            Logger.warning("[odr] Daily limit reached, retrying tomorrow")
            # Schedule for roughly next day or just stick to interval
            schedule_sync()

          {:error, reason} ->
            Logger.error("[odr] Sync failed: #{inspect(reason)}")
            Helper.ping_healthcheck(:fail, Config.healthchecks_ping_url())
            schedule_sync()
        end

      {:error, :not_ready} ->
        Logger.debug("[odr] Session not ready, retrying in 10s")
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
        threshold_s = System.os_time(:second) - div(Config.odr_sync_interval_ms(), 1000)
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
    ms = interval || Config.odr_sync_interval_ms()
    Process.send_after(self(), :sync, ms)
  end
end
