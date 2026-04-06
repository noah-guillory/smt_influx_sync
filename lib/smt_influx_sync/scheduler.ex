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
    Logger.info("SmtInfluxSync.Scheduler starting")

    case setup() do
      {:ok, state} ->
        # Run first sync immediately
        Process.send_after(self(), :sync, 0)
        {:ok, state}

      {:error, reason} ->
        Logger.error("Scheduler init failed: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  @impl true
  def handle_info(:sync, state) do
    state = do_sync(state)
    Process.send_after(self(), :sync, Config.sync_interval_ms())
    {:noreply, state}
  end

  # --- Private ---

  defp setup do
    with {:ok, token} <- SMTClient.authenticate(Config.smt_username(), Config.smt_password()),
         {:ok, {esiid, meter_number}} <- resolve_meter(token, Config.smt_esiid()) do
      Logger.info("Authenticated. ESIID=#{esiid} Meter=#{meter_number}")
      {:ok, %__MODULE__{token: token, esiid: esiid, meter_number: meter_number}}
    end
  end

  defp resolve_meter(token, "*") do
    case SMTClient.get_meters(token, "*") do
      {:ok, [%{esiid: esiid, meter_number: mn} | _]} ->
        {:ok, {esiid, mn}}

      {:ok, []} ->
        {:error, :no_meters_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resolve_meter(token, esiid) do
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
    Logger.info("Starting meter sync for ESIID=#{state.esiid}")

    case request_and_read(state) do
      {:ok, reading, state} ->
        timestamp = DateTime.to_unix(DateTime.utc_now())

        result =
          InfluxWriter.write(
            "electricity_usage",
            %{esiid: state.esiid, meter_number: state.meter_number},
            %{value: reading.value, usage: reading.usage},
            timestamp
          )

        case result do
          :ok ->
            Logger.info(
              "Wrote to InfluxDB: value=#{reading.value} kWh, usage=#{reading.usage} kWh (date=#{reading.date})"
            )

          {:error, reason} ->
            Logger.error("InfluxDB write error: #{inspect(reason)}")
        end

        state

      {:error, :rate_limited, state} ->
        Logger.warning("SMT rate limit hit — skipping this sync cycle")
        state

      {:error, reason, state} ->
        Logger.error("Sync failed: #{inspect(reason)}")
        state
    end
  end

  defp request_and_read(state) do
    case SMTClient.request_odr(state.token, state.esiid, state.meter_number) do
      :ok ->
        case SMTClient.poll_odr(state.token, state.esiid) do
          {:ok, reading} ->
            {:ok, reading, state}

          {:error, :unauthorized} ->
            with {:ok, state} <- reauthenticate(state),
                 {:ok, reading} <- SMTClient.poll_odr(state.token, state.esiid) do
              {:ok, reading, state}
            else
              {:error, reason} -> {:error, reason, state}
            end

          {:error, reason} ->
            {:error, reason, state}
        end

      {:error, :unauthorized} ->
        case reauthenticate(state) do
          {:ok, state} -> request_and_read(state)
          {:error, reason} -> {:error, reason, state}
        end

      {:error, :rate_limited} ->
        {:error, :rate_limited, state}

      {:error, reason} ->
        {:error, reason, state}
    end
  end

  defp reauthenticate(state) do
    Logger.info("Token expired, re-authenticating")

    case SMTClient.authenticate(Config.smt_username(), Config.smt_password()) do
      {:ok, token} -> {:ok, %{state | token: token}}
      {:error, reason} -> {:error, reason}
    end
  end
end
