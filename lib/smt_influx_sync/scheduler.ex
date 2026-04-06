defmodule SmtInfluxSync.Scheduler do
  use GenServer
  require Logger

  alias SmtInfluxSync.{Config, SMTClient, InfluxWriter}

  defstruct [:token, :esiid, :meter_number]

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @impl true
  def init([]) do
    Logger.info("Scheduler starting, authenticating with Smart Meter Texas")

    case setup() do
      {:ok, state} ->
        Logger.info("Scheduler ready, first sync starting immediately")
        Process.send_after(self(), :sync, 0)
        {:ok, state}

      {:error, reason} ->
        Logger.error("Scheduler init failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sync, state) do
    interval_min = div(Config.sync_interval_ms(), 60_000)
    Logger.info("Sync triggered — next sync in #{interval_min}m")
    state = do_sync(state)
    Process.send_after(self(), :sync, Config.sync_interval_ms())
    {:noreply, state}
  end

  # --- Private ---

  defp setup do
    with {:ok, token} <- load_or_authenticate(),
         {:ok, {esiid, meter_number}} <-
           resolve_meter(token, Config.smt_esiid(), Config.smt_meter_number()) do
      Logger.info("Meter resolved — ESIID=#{esiid} MeterNumber=#{meter_number}")
      {:ok, %__MODULE__{token: token, esiid: esiid, meter_number: meter_number}}
    end
  end

  defp load_or_authenticate do
    case read_token() do
      {:ok, token} ->
        Logger.info("Loaded persisted token from #{Config.token_path()}")
        {:ok, token}

      :error ->
        Logger.info("No persisted token found, authenticating with Smart Meter Texas")
        authenticate_and_save()
    end
  end

  defp authenticate_and_save do
    case SMTClient.authenticate(Config.smt_username(), Config.smt_password()) do
      {:ok, token} ->
        Logger.info("Authentication successful")
        save_token(token)
        {:ok, token}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp read_token do
    path = Config.token_path()

    case File.read(path) do
      {:ok, token} -> {:ok, String.trim(token)}
      {:error, _} -> :error
    end
  end

  defp save_token(token) do
    path = Config.token_path()
    path |> Path.dirname() |> File.mkdir_p!()

    case File.write(path, token) do
      :ok -> Logger.info("Token persisted to #{path}")
      {:error, reason} -> Logger.warning("Failed to persist token: #{inspect(reason)}")
    end
  end

  defp resolve_meter(_token, esiid, meter_number)
       when is_binary(esiid) and esiid != "*" and is_binary(meter_number) do
    Logger.info("Using configured ESIID=#{esiid} Meter=#{meter_number}")
    {:ok, {esiid, meter_number}}
  end

  defp resolve_meter(token, "*", _meter_number) do
    Logger.info("No ESIID configured, fetching all meters from account")

    case SMTClient.get_meters(token, "*") do
      {:ok, [%{esiid: esiid, meter_number: mn} | rest]} ->
        if rest != [], do: Logger.warning("Multiple meters found, using first (ESIID=#{esiid})")
        {:ok, {esiid, mn}}

      {:ok, []} ->
        {:error, :no_meters_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_meter(token, esiid, _meter_number) do
    Logger.info("Fetching meter info for ESIID=#{esiid}")

    case SMTClient.get_meters(token, esiid) do
      {:ok, [%{esiid: ^esiid, meter_number: mn} | _]} ->
        {:ok, {esiid, mn}}

      {:ok, []} ->
        {:error, {:meter_not_found, esiid}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp do_sync(state) do
    Logger.info("[sync] Checking latest read for ESIID=#{state.esiid}")
    ping_healthcheck(:start)

    odr_ok =
      case request_and_read(state) do
        {:ok, reading, state} ->
          timestamp =
            case SMTClient.parse_odr_date(reading.date) do
              {:ok, unix} -> unix
              :error -> DateTime.to_unix(DateTime.utc_now())
            end

          Logger.info("[sync] Got reading — value=#{reading.value} kWh, usage=#{reading.usage} kWh, read_date=#{reading.date}")
          Logger.info("[sync] Writing to InfluxDB")

          case InfluxWriter.write(
                 "electricity_usage",
                 %{esiid: state.esiid, meter_number: state.meter_number, source: "odr"},
                 %{value: reading.value, usage: reading.usage},
                 timestamp
               ) do
            :ok ->
              Logger.info("[sync] Write accepted")
              true

            {:error, reason} ->
              Logger.error("[sync] InfluxDB write error: #{inspect(reason)}")
              false
          end

        {:error, :rate_limited, _state} ->
          Logger.warning("[sync] SMT rate limit hit — skipping this cycle")
          false

        {:error, reason, _state} ->
          Logger.error("[sync] Failed: #{inspect(reason)}")
          false
      end

    historical_ok = sync_historical(state)

    if odr_ok and historical_ok,
      do: ping_healthcheck(:success),
      else: ping_healthcheck(:fail)

    state
  end

  defp sync_historical(state) do
    today = Date.utc_today()
    base_tags = %{esiid: state.esiid, meter_number: state.meter_number}

    interval_ok = sync_interval(state, Map.put(base_tags, :source, "interval"), today)
    daily_ok = sync_daily(state, Map.put(base_tags, :source, "daily"), today)
    monthly_ok = sync_monthly(state, Map.put(base_tags, :source, "monthly"), today)

    interval_ok and daily_ok and monthly_ok
  end

  defp sync_interval(state, tags, end_date) do
    start_date = last_sync_start("interval", end_date)
    Logger.info("[sync] Fetching interval data #{SMTClient.format_date(start_date)}–#{SMTClient.format_date(end_date)}")

    case SMTClient.get_interval_data(state.token, state.esiid, start_date, end_date) do
      {:ok, records} ->
        Logger.info("[sync] Got #{length(records)} interval records")
        ok = write_records("electricity_interval", tags, records, &parse_interval_record/1)
        if ok, do: save_last_sync("interval", end_date)
        ok

      {:error, reason} ->
        Logger.error("[sync] Interval data fetch failed: #{inspect(reason)}")
        false
    end
  end

  defp sync_daily(state, tags, end_date) do
    start_date = last_sync_start("daily", end_date)
    Logger.info("[sync] Fetching daily data #{SMTClient.format_date(start_date)}–#{SMTClient.format_date(end_date)}")

    case SMTClient.get_daily_data(state.token, state.esiid, start_date, end_date) do
      {:ok, records} ->
        Logger.info("[sync] Got #{length(records)} daily records")
        ok = write_records("electricity_daily", tags, records, &parse_daily_record/1)
        if ok, do: save_last_sync("daily", end_date)
        ok

      {:error, reason} ->
        Logger.error("[sync] Daily data fetch failed: #{inspect(reason)}")
        false
    end
  end

  defp sync_monthly(state, tags, end_date) do
    start_date = last_sync_start("monthly", end_date)
    Logger.info("[sync] Fetching monthly data #{SMTClient.format_date(start_date)}–#{SMTClient.format_date(end_date)}")

    case SMTClient.get_monthly_data(state.token, state.esiid, start_date, end_date) do
      {:ok, records} ->
        Logger.info("[sync] Got #{length(records)} monthly records")
        ok = write_records("electricity_monthly", tags, records, &parse_monthly_record/1)
        if ok, do: save_last_sync("monthly", end_date)
        ok

      {:error, reason} ->
        Logger.error("[sync] Monthly data fetch failed: #{inspect(reason)}")
        false
    end
  end

  # Returns the start date for a sync window.
  # On first run (no saved date): 365 days ago.
  # On subsequent runs: the day after the last successful sync, capped at 365 days ago.
  # We overlap by 1 day so partially-available data from the previous sync end gets a retry.
  defp last_sync_start(source, today) do
    floor = Date.add(today, -365)

    case File.read(Config.last_sync_path(source)) do
      {:ok, contents} ->
        case Date.from_iso8601(String.trim(contents)) do
          {:ok, last_date} ->
            candidate = Date.add(last_date, -1)
            if Date.compare(candidate, floor) == :lt, do: floor, else: candidate
          _ -> floor
        end

      {:error, _} ->
        floor
    end
  end

  defp save_last_sync(source, date) do
    path = Config.last_sync_path(source)
    path |> Path.dirname() |> File.mkdir_p!()

    case File.write(path, Date.to_iso8601(date)) do
      :ok -> :ok
      {:error, reason} -> Logger.warning("[sync] Failed to save last sync date for #{source}: #{inspect(reason)}")
    end
  end

  defp write_records(measurement, tags, records, parser) do
    Enum.reduce(records, true, fn record, ok ->
      case parser.(record) do
        {:ok, fields, timestamp} ->
          case InfluxWriter.write(measurement, tags, fields, timestamp) do
            :ok ->
              ok

            {:error, reason} ->
              Logger.error("[sync] InfluxDB write error for #{measurement}: #{inspect(reason)}")
              false
          end

        :skip ->
          ok
      end
    end)
  end

  # Interval: {date: "2026-04-05", starttime: " 12:00 am", consumption: 0.226, generation: 0}
  defp parse_interval_record(%{"date" => date_str, "starttime" => time_str, "consumption" => consumption} = record) do
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

  defp parse_interval_record(_), do: :skip

  # Daily: {date: "12/04/2025", reading: 37.86, startreading: "72366.148", endreading: "72404.005"}
  defp parse_daily_record(%{"date" => date_str, "reading" => reading} = record) do
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

  defp parse_daily_record(_), do: :skip

  # Monthly: {startdate: "04/15/2024", actl_kwh_usg: 1074, mtrd_kwh_usg: 0, blld_kwh_usg: 0}
  defp parse_monthly_record(%{"startdate" => date_str, "actl_kwh_usg" => actl_kwh} = record) do
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

  defp parse_monthly_record(_), do: :skip

  # ISO date "2026-04-05" + 12h time " 12:00 am" → Unix timestamp in configured timezone
  defp parse_interval_timestamp(date_str, time_str) do
    with {:ok, date} <- Date.from_iso8601(date_str),
         {:ok, {h, m}} <- parse_12h_time(time_str),
         {:ok, time} <- Time.new(h, m, 0),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      {:ok, DateTime.to_unix(DateTime.from_naive!(naive, Config.timezone()))}
    else
      _ -> :error
    end
  end

  # " 12:00 am" / "1:15 pm" → {hour24, minute}
  defp parse_12h_time(time_str) do
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
  defp parse_mdy_date(date_str) do
    case Regex.run(~r/^(\d{2})\/(\d{2})\/(\d{4})$/, date_str) do
      [_, mo, d, y] ->
        case Date.new(String.to_integer(y), String.to_integer(mo), String.to_integer(d)) do
          {:ok, date} ->
            naive = NaiveDateTime.new!(date, ~T[00:00:00])
            {:ok, DateTime.to_unix(DateTime.from_naive!(naive, Config.timezone()))}

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  defp parse_float_str(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> {:ok, f}
      :error -> :error
    end
  end

  defp parse_float_str(_), do: :error

  defp ping_healthcheck(signal) do
    case Config.healthchecks_ping_url() do
      nil ->
        :ok

      base_url ->
        url =
          case signal do
            :start -> "#{base_url}/start"
            :success -> base_url
            :fail -> "#{base_url}/fail"
          end

        case Req.get(url, retry: false) do
          {:ok, %{status: status}} when status in 200..299 ->
            Logger.debug("[healthchecks] Pinged #{signal}")

          {:ok, %{status: status}} ->
            Logger.warning("[healthchecks] Ping #{signal} returned HTTP #{status}")

          {:error, reason} ->
            Logger.warning("[healthchecks] Ping #{signal} failed: #{inspect(reason)}")
        end
    end
  end

  defp request_and_read(state) do
    case check_recent_read(state) do
      {:reuse, reading} ->
        Logger.info("Reusing recent read from #{reading.date}, skipping ODR request")
        {:ok, reading, state}

      :stale ->
        request_odr_and_read(state)
    end
  end

  # Returns {:reuse, reading} if the latest read is within the sync window, else :stale.
  defp check_recent_read(state) do
    Logger.info("[sync] Fetching latest ODR read from SMT")

    case SMTClient.get_latest_read(state.token, state.esiid) do
      {:ok, :no_data} ->
        Logger.info("[sync] No existing read data, will request new ODR")
        :stale

      {:ok, reading} ->
        threshold_s = System.os_time(:second) - div(Config.sync_interval_ms(), 1000)

        case SMTClient.parse_odr_date(reading.date) do
          {:ok, read_unix} when read_unix >= threshold_s ->
            age_min = div(System.os_time(:second) - read_unix, 60)
            Logger.info("[sync] Latest read is #{age_min}m old (within sync window), reusing")
            {:reuse, reading}

          {:ok, read_unix} ->
            age_min = div(System.os_time(:second) - read_unix, 60)
            Logger.info("[sync] Latest read is #{age_min}m old (outside sync window), requesting new ODR")
            :stale

          :error ->
            Logger.warning("[sync] Could not parse read date #{inspect(reading.date)}, requesting new ODR")
            :stale
        end

      {:error, reason} ->
        Logger.warning("[sync] Could not fetch latest read (#{inspect(reason)}), proceeding with ODR")
        :stale
    end
  end

  defp request_odr_and_read(state) do
    Logger.info("[sync] Requesting on-demand read from SMT")

    case SMTClient.request_odr(state.token, state.esiid, state.meter_number) do
      :ok ->
        Logger.info("[sync] ODR accepted, polling for result")

        case SMTClient.poll_odr(state.token, state.esiid) do
          {:ok, reading} ->
            Logger.info("[sync] ODR completed")
            {:ok, reading, state}

          {:error, :unauthorized} ->
            Logger.info("[sync] Token expired during poll, re-authenticating")

            with {:ok, state} <- reauthenticate(state),
                 {:ok, reading} <- SMTClient.poll_odr(state.token, state.esiid) do
              {:ok, reading, state}
            else
              {:error, reason} -> {:error, reason, state}
            end

          {:error, :timeout} ->
            Logger.warning("[sync] ODR polling timed out waiting for COMPLETED status")
            {:error, :timeout, state}

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, :unauthorized} ->
        Logger.info("[sync] Token expired, re-authenticating before ODR")

        case reauthenticate(state) do
          {:ok, state} -> request_odr_and_read(state)
          {:error, reason} -> {:error, reason, state}
        end

      {:error, :rate_limited} ->
        {:error, :rate_limited, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp reauthenticate(state) do
    Logger.info("Token rejected (401), re-authenticating")

    case authenticate_and_save() do
      {:ok, token} -> {:ok, %{state | token: token}}
      {:error, reason} -> {:error, reason}
    end
  end
end
