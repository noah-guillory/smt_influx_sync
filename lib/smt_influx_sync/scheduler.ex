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
               %{esiid: state.esiid, meter_number: state.meter_number},
               %{value: reading.value, usage: reading.usage},
               timestamp
             ) do
          :ok ->
            Logger.info("[sync] Write accepted")

          {:error, reason} ->
            Logger.error("[sync] InfluxDB write error: #{inspect(reason)}")
        end

        state

      {:error, :rate_limited, state} ->
        Logger.warning("[sync] SMT rate limit hit — skipping this cycle")
        state

      {:error, reason, state} ->
        Logger.error("[sync] Failed: #{inspect(reason)}")
        state
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
