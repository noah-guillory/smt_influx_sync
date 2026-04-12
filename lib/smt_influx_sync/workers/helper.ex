defmodule SmtInfluxSync.Workers.Helper do
  @moduledoc """
  Shared helper functions for SMT sync workers.
  """
  require Logger
  alias SmtInfluxSync.{Config, InfluxWriter}

  @doc """
  Returns the start date for a sync window.
  """
  def last_sync_start(source, today) do
    lookback = Config.initial_lookback_days()
    floor = Date.add(today, -lookback)
    
    case SmtInfluxSync.SyncMetadata.get_latest_sync(source) do
      %{completed_at: completed_at} ->
        last_date = DateTime.to_date(completed_at)
        # Overlap by 1 day so partially-available data from the previous sync end gets a retry.
        candidate = Date.add(last_date, -1)
        
        if Date.compare(candidate, floor) == :lt do
          Logger.debug("[#{source}] Saved sync date #{last_date} from DB is older than lookback (#{lookback} days), using floor")
          floor
        else
          Logger.debug("[#{source}] Resuming from saved sync date #{last_date} from DB (overlap 1 day)")
          candidate
        end

      nil ->
        # Fallback to file for migration or first run
        path = Config.last_sync_path(source)
        
        case File.read(path) do
          {:ok, contents} ->
            case Date.from_iso8601(String.trim(contents)) do
              {:ok, last_date} ->
                Date.add(last_date, -1)
              _ ->
                floor
            end
          _ ->
            Logger.info("[#{source}] No sync marker found in DB or file, performing full initial sync (lookback #{lookback} days)")
            floor
        end
    end
  end

  @doc """
  Saves the last successful sync date.
  """
  def save_last_sync(source, date) do
    # Still write to file for backup/compatibility
    path = Config.last_sync_path(source)
    path |> Path.dirname() |> File.mkdir_p!()
    File.write(path, Date.to_iso8601(date))

    # Log success in DB (mimic start/success for these older calls)
    log = SmtInfluxSync.SyncMetadata.log_start(source, "Saved date: #{date}")
    SmtInfluxSync.SyncMetadata.log_success(log, "Sync completed for date: #{date}")
    :ok
  end

  @doc """
  Saves the current timestamp and timezone as the last successful sync.
  """
  def save_last_sync_now(source) do
    # Still write to file for backup/compatibility
    path = Config.last_sync_path(source)
    path |> Path.dirname() |> File.mkdir_p!()
    now = DateTime.now!(Config.timezone())
    timestamp = Calendar.strftime(now, "%Y-%m-%d %H:%M:%S %Z")
    File.write(path, timestamp)

    # Log success in DB
    log = SmtInfluxSync.SyncMetadata.log_start(source, "Saved timestamp: #{timestamp}")
    SmtInfluxSync.SyncMetadata.log_success(log, "Sync completed at: #{timestamp}")
    :ok
  end

  @doc """
  Writes a batch of records to InfluxDB after parsing them.
  """
  def write_records(measurement, tags, records, parser) do
    entries =
      Enum.flat_map(records, fn record ->
        case parser.(record) do
          {:ok, fields, timestamp} -> [{measurement, tags, fields, timestamp}]
          :skip -> []
        end
      end)

    InfluxWriter.write_batch(entries) == :ok
  end

  # --- Parsers ---

  # Interval: {date: "2026-04-05", starttime: " 12:00 am", consumption: 0.226, generation: 0}
  def parse_interval_record(%{"date" => date_str, "starttime" => time_str, "consumption" => consumption} = record) do
    case parse_interval_timestamp(date_str, time_str) do
      {:ok, timestamp} ->
        fields = %{consumption: consumption / 1.0}

        fields =
          case record["generation"] do
            v when is_number(v) -> Map.put(fields, :generation, v / 1.0)
            _ -> fields
          end

        {:ok, fields, timestamp}

      :error ->
        :skip
    end
  end

  def parse_interval_record(_), do: :skip

  # Daily: {date: "12/04/2025", reading: 37.86, startreading: "72366.148", endreading: "72404.005"}
  def parse_daily_record(%{"date" => date_str, "reading" => reading} = record) do
    case parse_mdy_date(date_str) do
      {:ok, timestamp} ->
        fields = %{reading: reading / 1.0}

        fields =
          case parse_float_str(record["startreading"]) do
            {:ok, v} -> Map.put(fields, :startreading, v)
            :error -> fields
          end

        fields =
          case parse_float_str(record["endreading"]) do
            {:ok, v} -> Map.put(fields, :endreading, v)
            :error -> fields
          end

        {:ok, fields, timestamp}

      :error ->
        :skip
    end
  end

  def parse_daily_record(_), do: :skip

  # Monthly: {startdate: "04/15/2024", actl_kwh_usg: 1074, mtrd_kwh_usg: 0, blld_kwh_usg: 0}
  def parse_monthly_record(%{"startdate" => date_str, "actl_kwh_usg" => actl_kwh} = record) do
    case parse_mdy_date(date_str) do
      {:ok, timestamp} ->
        fields = %{
          actl_kwh_usg: actl_kwh / 1.0,
          mtrd_kwh_usg: record["mtrd_kwh_usg"] / 1.0,
          blld_kwh_usg: record["blld_kwh_usg"] / 1.0
        }

        {:ok, fields, timestamp}

      :error ->
        :skip
    end
  end

  def parse_monthly_record(_), do: :skip

  # ISO date "2026-04-05" + 12h time " 12:00 am" → Unix timestamp in configured timezone
  def parse_interval_timestamp(date_str, time_str) do
    with {:ok, date} <- Date.from_iso8601(date_str),
         {:ok, {h, m}} <- parse_12h_time(time_str),
         {:ok, time} <- Time.new(h, m, 0),
         {:ok, naive} <- NaiveDateTime.new(date, time),
         {:ok, unix} <- naive_to_unix(naive) do
      {:ok, unix}
    else
      _ -> :error
    end
  end

  # " 12:00 am" / "1:15 pm" → {hour24, minute}
  def parse_12h_time(time_str) do
    case Regex.run(~r/^\s*(\d{1,2}):(\d{2})\s*(am|pm)$/i, time_str) do
      [_, h_str, m_str, period] ->
        h = String.to_integer(h_str)
        m = String.to_integer(m_str)

        h24 =
          case String.downcase(period) do
            "am" -> if h == 12, do: 0, else: h
            "pm" -> if h == 12, do: 12, else: h + 12
          end

        {:ok, {h24, m}}

      _ ->
        :error
    end
  end

  # "MM/DD/YYYY" → Unix timestamp at midnight in configured timezone
  def parse_mdy_date(date_str) do
    case Regex.run(~r/^(\d{2})\/(\d{2})\/(\d{4})$/, date_str) do
      [_, mo, d, y] ->
        case Date.new(String.to_integer(y), String.to_integer(mo), String.to_integer(d)) do
          {:ok, date} ->
            naive = NaiveDateTime.new!(date, ~T[00:00:00])
            naive_to_unix(naive)

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  # Converts a NaiveDateTime to a Unix timestamp in the configured timezone.
  def naive_to_unix(naive) do
    case DateTime.from_naive(naive, Config.timezone()) do
      {:ok, dt} -> {:ok, DateTime.to_unix(dt)}
      {:ambiguous, dt, _} -> {:ok, DateTime.to_unix(dt)}
      {:gap, _, dt} -> {:ok, DateTime.to_unix(dt)}
      {:error, reason} -> {:error, reason}
    end
  end

  def parse_float_str(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> {:ok, f}
      :error -> :error
    end
  end

  def parse_float_str(_), do: :error

  def ping_healthcheck(signal, url) do
    case url do
      nil ->
        :ok

      base_url ->
        full_url =
          case signal do
            :start -> "#{base_url}/start"
            :success -> base_url
            :fail -> "#{base_url}/fail"
          end

        case Req.get(full_url, retry: false) do
          {:ok, %{status: status}} when status in 200..299 ->
            Logger.debug("[healthchecks] Pinged #{signal}")

          {:ok, %{status: status}} ->
            Logger.warning("[healthchecks] Ping #{signal} returned HTTP #{status}")

          {:error, reason} ->
            Logger.warning("[healthchecks] Ping #{signal} failed: #{inspect(reason)}")
        end
    end
  end
end
