defmodule SmtInfluxSync.Workers.ODR do
  @moduledoc """
  Oban worker for On-Demand Read (ODR) sync.
  """
  use Oban.Worker, queue: :default, max_attempts: 3
  require Logger

  alias SmtInfluxSync.{Config, SMTClient, InfluxWriter}
  alias SmtInfluxSync.SMT.Session
  alias SmtInfluxSync.Workers.Helper

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Session.get_token() do
      {:ok, token} ->
        active_meters = SmtInfluxSync.Meter.list_active()

        if active_meters == [] do
          Logger.warning("[odr] No active meters found, skipping sync")
          schedule_next()
          :ok
        else
          results = 
            Enum.map(active_meters, fn meter ->
              Logger.metadata(worker: :odr, esiid: meter.esiid)
              Logger.info("[odr] Starting sync")
              sync_log = SmtInfluxSync.SyncMetadata.log_start("odr", "ESIID: #{meter.esiid}")
              started_at = System.monotonic_time(:millisecond)

              case do_sync(token, meter) do
                {:ok, timestamp} ->
                  elapsed = System.monotonic_time(:millisecond) - started_at
                  Logger.info("[odr] Sync completed successfully in #{elapsed}ms")
                  
                  latest_dt = if timestamp, do: DateTime.from_unix!(timestamp), else: nil
                  SmtInfluxSync.SyncMetadata.log_success(sync_log, "Fetched 1 record in #{elapsed}ms", nil, latest_dt)
                  if timestamp, do: SmtInfluxSync.Meter.update_last_data_point(meter.id, "odr", timestamp)
                  :ok

                {:error, :rate_limited} ->
                  Logger.warning("[odr] Rate limited, retrying later")
                  SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Rate limited")
                  {:error, :rate_limited}

                {:error, :daily_limit_reached} ->
                  Logger.warning("[odr] Daily limit reached, retrying tomorrow")
                  SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Daily limit reached")
                  :ok # Don't retry, just wait for next day

                {:error, :unauthorized} ->
                  Session.refresh_token()
                  SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Unauthorized, token refreshed")
                  {:error, :unauthorized}

                {:error, reason} ->
                  Logger.error("[odr] Sync failed: #{inspect(reason)}")
                  SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Sync failed: #{inspect(reason)}")
                  {:error, reason}
              end
            end)

          if Enum.all?(results, &(&1 == :ok or &1 == :daily_limit_reached)) do
             Helper.save_last_sync_now("odr")
             Helper.ping_healthcheck(:success, Config.healthchecks_ping_url())
          end

          schedule_next()
          
          if Enum.any?(results, &(&1 == {:error, :unauthorized})) do
            {:error, :unauthorized}
          else
            :ok
          end
        end

      {:error, :not_ready} ->
        Logger.debug("[odr] Session not ready, retrying in 1 minute")
        {:error, :not_ready}
    end
  end

  def schedule_next do
    {h, m} = Config.parse_time_string(Config.odr_sync_time())
    ms = Helper.ms_until_next_time(h, m)
    
    %{}
    |> __MODULE__.new(scheduled_at: DateTime.add(DateTime.utc_now(), ms, :millisecond))
    |> Oban.insert!()
  end

  # --- Private ---

  defp do_sync(token, meter) do
    case request_and_read(token, meter) do
      {:ok, reading} ->
        timestamp =
          case SMTClient.parse_odr_date(reading.date) do
            {:ok, unix} -> unix
            :error -> DateTime.to_unix(DateTime.utc_now())
          end

        case InfluxWriter.write(
          "electricity_usage",
          %{esiid: meter.esiid, meter_number: meter.meter_number, source: "odr"},
          %{value: reading.value, usage: reading.usage},
          timestamp
        ) do
          :ok -> {:ok, timestamp}
          {:error, reason} -> {:error, reason}
        end

      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request_and_read(token, meter) do
    case check_recent_read(token, meter) do
      {:reuse, reading} ->
        Logger.info("[odr] Reusing recent read from #{reading.date}")
        {:ok, reading}

      :stale ->
        request_odr_and_read(token, meter)
    end
  end

  defp check_recent_read(token, meter) do
    case SMTClient.get_latest_read(token, meter.esiid) do
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

  defp request_odr_and_read(token, meter) do
    limit = Config.odr_daily_limit()
    count = odr_daily_count(meter.esiid)

    if count >= limit do
      {:error, :daily_limit_reached}
    else
      execute_odr_request(token, meter)
    end
  end

  defp execute_odr_request(token, meter) do
    case SMTClient.request_odr(token, meter.esiid, meter.meter_number) do
      :ok ->
        increment_odr_daily_count(meter.esiid)
        SMTClient.poll_odr(token, meter.esiid)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp odr_daily_count(esiid) do
    today = Date.to_iso8601(Date.utc_today())
    path = Config.odr_daily_count_path() <> "_#{esiid}"

    case File.read(path) do
      {:ok, contents} ->
        case String.split(String.trim(contents), "\n") do
          [^today, count_str] -> String.to_integer(count_str)
          _ -> 0
        end
      {:error, _} -> 0
    end
  end

  defp increment_odr_daily_count(esiid) do
    count = odr_daily_count(esiid) + 1
    today = Date.to_iso8601(Date.utc_today())
    path = Config.odr_daily_count_path() <> "_#{esiid}"
    path |> Path.dirname() |> File.mkdir_p!()
    File.write(path, "#{today}\n#{count}")
  end
end
