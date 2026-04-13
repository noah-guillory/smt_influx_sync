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
  def perform(%Oban.Job{args: args}) do
    case Session.get_token() do
      {:ok, token} ->
        active_meters = SmtInfluxSync.Meter.list_active()

        if active_meters == [] do
          Logger.warning("[monthly] No active meters found, skipping sync")
          schedule_next()
          :ok
        else
          results = 
            Enum.map(active_meters, fn meter ->
              Logger.metadata(worker: :monthly, esiid: meter.esiid)

              custom_range = 
                case args do
                  %{"start_date" => start_str, "end_date" => end_str} ->
                    with {:ok, start_date} <- Date.from_iso8601(start_str),
                         {:ok, end_date} <- Date.from_iso8601(end_str) do
                      {start_date, end_date}
                    else
                      _ -> nil
                    end
                  _ -> nil
                end

              msg = if custom_range, do: "[monthly] Starting custom range sync", else: "[monthly] Starting sync"
              Logger.info(msg)
              sync_log = SmtInfluxSync.SyncMetadata.log_start("monthly", if(custom_range, do: "ESIID: #{meter.esiid}, Range: #{args["start_date"]} to #{args["end_date"]}", else: "ESIID: #{meter.esiid}"))
              started_at = System.monotonic_time(:millisecond)

              case do_sync(token, meter, custom_range) do
                {:ok, max_ts} ->
                  elapsed = System.monotonic_time(:millisecond) - started_at
                  Logger.info("[monthly] Sync completed successfully in #{elapsed}ms")
                  
                  latest_dt = if max_ts, do: DateTime.from_unix!(max_ts), else: nil
                  SmtInfluxSync.SyncMetadata.log_success(sync_log, "Sync completed in #{elapsed}ms", nil, latest_dt)
                  if max_ts, do: SmtInfluxSync.Meter.update_last_data_point(meter.id, "monthly", max_ts)
                  :ok

                {:error, :unauthorized} ->
                  Session.refresh_token()
                  SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Unauthorized, token refreshed")
                  {:error, :unauthorized}

                {:error, reason} ->
                  Logger.error("[monthly] Sync failed: #{inspect(reason)}")
                  SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Sync failed: #{inspect(reason)}")
                  {:error, reason}
              end
            end)

          unless Enum.any?(args, fn {k, _} -> k in ["start_date", "end_date"] end), do: schedule_next()

          if Enum.any?(results, &(&1 == {:error, :unauthorized})) do
            {:error, :unauthorized}
          else
            :ok
          end
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

  defp do_sync(token, meter, custom_range) do
    today = Date.utc_today()
    tags = %{esiid: meter.esiid, meter_number: meter.meter_number, source: "monthly"}
    
    {start_date, end_date} = 
      case custom_range do
        {s, e} -> {s, e}
        nil -> {Helper.last_sync_start("monthly", today), today}
      end

    Logger.info("[monthly] Fetching #{SMTClient.format_date(start_date)}–#{SMTClient.format_date(end_date)}")

    case SMTClient.get_monthly_data(token, meter.esiid, start_date, end_date) do
      {:ok, records} ->
        Logger.info("[monthly] Fetched #{length(records)} records")
        case Helper.write_records("electricity_monthly", tags, records, &Helper.parse_monthly_record/1) do
          {:ok, max_ts} ->
            unless custom_range, do: Helper.save_last_sync("monthly", end_date)
            {:ok, max_ts}
        end

      {:error, :unauthorized} -> {:error, :unauthorized}
      {:error, reason} -> {:error, reason}
    end
  end
end
