defmodule SmtInfluxSync.SMT.Session do
  @moduledoc """
  Supervisor for the SMT session and its dependent sync workers.
  """
  use Supervisor

  def start_link(opts) do
    Supervisor.start_link(__MODULE__, :ok, opts)
  end

  @impl true
  def init(:ok) do
    children = [
      {SmtInfluxSync.SMT.Session.Manager, [name: SmtInfluxSync.SMT.Session.Manager]},
      SmtInfluxSync.Workers.ODR,
      SmtInfluxSync.Workers.Interval,
      SmtInfluxSync.Workers.Daily,
      SmtInfluxSync.Workers.Monthly
    ]

    # :rest_for_one means if Session.Manager crashes, all workers are restarted.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  # --- Public API Delegation ---

  def get_credentials do
    SmtInfluxSync.SMT.Session.Manager.get_credentials()
  end

  def refresh_token do
    SmtInfluxSync.SMT.Session.Manager.refresh_token()
  end

  # --- Manager Implementation ---

  defmodule Manager do
    @moduledoc """
    GenServer that manages the actual SMT authentication state.
    """
    use GenServer
    require Logger
    alias SmtInfluxSync.{Config, SMTClient}

    @type state :: %{
            token: String.t() | nil,
            esiid: String.t() | nil,
            meter_number: String.t() | nil,
            resolved: boolean()
          }

    def start_link(opts) do
      GenServer.start_link(__MODULE__, [], opts)
    end

    def get_credentials(server \\ __MODULE__) do
      GenServer.call(server, :get_credentials)
    end

    def refresh_token(server \\ __MODULE__) do
      GenServer.call(server, :refresh_token)
    end

    @impl true
    def init([]) do
      Logger.info("[session] Starting SMT session manager")
      send(self(), :setup)
      {:ok, %{token: nil, esiid: nil, meter_number: nil, resolved: false}}
    end

    @impl true
    def handle_call(:get_credentials, _from, %{resolved: true} = state) do
      {:reply, {:ok, %{token: state.token, esiid: state.esiid, meter_number: state.meter_number}},
       state}
    end

    def handle_call(:get_credentials, _from, state) do
      {:reply, {:error, :not_ready}, state}
    end

    @impl true
    def handle_call(:refresh_token, _from, state) do
      Logger.info("[session] Refreshing SMT token")

      case authenticate_and_save() do
        {:ok, token} ->
          {:reply, :ok, %{state | token: token}}

        {:error, reason} ->
          Logger.error("[session] Token refresh failed: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    end

    @impl true
    def handle_info(:setup, state) do
      case setup() do
        {:ok, new_state} ->
          Logger.info(
            "[session] Ready — ESIID=#{new_state.esiid} MeterNumber=#{new_state.meter_number}"
          )

          {:noreply, Map.put(new_state, :resolved, true)}

        {:error, reason} ->
          Logger.error("[session] Setup failed: #{inspect(reason)}. Retrying in 1 minute...")
          Process.send_after(self(), :setup, 60_000)
          {:noreply, state}
      end
    end

    # --- Private ---

    defp setup do
      with {:ok, token} <- load_or_authenticate(),
           {:ok, {esiid, meter_number}} <-
             resolve_meter(token, Config.smt_esiid(), Config.smt_meter_number()) do
        {:ok, %{token: token, esiid: esiid, meter_number: meter_number}}
      end
    end

    defp load_or_authenticate do
      case read_token() do
        {:ok, token} ->
          Logger.info("[session] Loaded persisted token from #{Config.token_path()}")
          {:ok, token}

        :error ->
          Logger.info("[session] No valid persisted token found, authenticating")
          authenticate_and_save()
      end
    end

    defp authenticate_and_save do
      case SMTClient.authenticate(Config.smt_username(), Config.smt_password()) do
        {:ok, token} ->
          Logger.info("[session] Authentication successful")
          save_token(token)
          {:ok, token}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp read_token do
      path = Config.token_path()

      case File.read(path) do
        {:ok, token} ->
          token = String.trim(token)
          if token == "", do: :error, else: {:ok, token}

        {:error, _} ->
          :error
      end
    end

    defp save_token(token) do
      path = Config.token_path()
      path |> Path.dirname() |> File.mkdir_p!()

      case File.write(path, token) do
        :ok -> Logger.info("[session] Token persisted to #{path}")
        {:error, reason} -> Logger.warning("[session] Failed to persist token: #{inspect(reason)}")
      end
    end

    defp resolve_meter(_token, esiid, meter_number)
         when is_binary(esiid) and esiid != "*" and is_binary(meter_number) do
      {:ok, {esiid, meter_number}}
    end

    defp resolve_meter(token, "*", _meter_number) do
      case SMTClient.get_meters(token, "*") do
        {:ok, [%{esiid: esiid, meter_number: mn} | rest]} ->
          if rest != [],
            do: Logger.warning("[session] Multiple meters found, using first (ESIID=#{esiid})")

          {:ok, {esiid, mn}}

        {:ok, []} ->
          {:error, :no_meters_found}

        {:error, reason} ->
          {:error, reason}
      end
    end

    defp resolve_meter(token, esiid, _meter_number) do
      case SMTClient.get_meters(token, esiid) do
        {:ok, [%{esiid: ^esiid, meter_number: mn} | _]} ->
          {:ok, {esiid, mn}}

        {:ok, []} ->
          {:error, {:meter_not_found, esiid}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
