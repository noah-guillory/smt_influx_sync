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
      {SmtInfluxSync.SMT.Session.Manager, [name: SmtInfluxSync.SMT.Session.Manager]}
    ]

    # :rest_for_one means if Session.Manager crashes, all workers are restarted.
    Supervisor.init(children, strategy: :rest_for_one)
  end

  # --- Public API Delegation ---

  def get_token do
    SmtInfluxSync.SMT.Session.Manager.get_token()
  end

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
            resolved: boolean()
          }

    def start_link(opts) do
      GenServer.start_link(__MODULE__, [], opts)
    end

    def get_token(server \\ __MODULE__) do
      GenServer.call(server, :get_token)
    end

    def get_credentials(server \\ __MODULE__) do
      # Backwards compatibility for single-meter logic if needed,
      # but we should move away from this.
      GenServer.call(server, :get_credentials)
    end

    def refresh_token(server \\ __MODULE__) do
      GenServer.call(server, :refresh_token)
    end

    @impl true
    def init([]) do
      Logger.info("[session] Starting SMT session manager")
      send(self(), :setup)
      {:ok, %{token: nil, resolved: false}}
    end

    @impl true
    def handle_call(:get_token, _from, %{resolved: true} = state) do
      {:reply, {:ok, state.token}, state}
    end

    @impl true
    def handle_call(:get_token, _from, state) do
      {:reply, {:error, :not_ready}, state}
    end

    @impl true
    def handle_call(:get_credentials, _from, %{resolved: true} = state) do
      # Return the first active meter as "primary" for legacy workers
      case SmtInfluxSync.Meter.list_active() do
        [m | _] ->
          {:reply, {:ok, %{token: state.token, esiid: m.esiid, meter_number: m.meter_number}}, state}
        [] ->
          {:reply, {:error, :no_active_meters}, state}
      end
    end

    def handle_call(:get_credentials, _from, state) do
      {:reply, {:error, :not_ready}, state}
    end

    @impl true
    def handle_call(:refresh_token, _from, state) do
      Logger.info("Refreshing SMT token")

      case authenticate_and_save() do
        {:ok, token} ->
          {:reply, :ok, %{state | token: token}}

        {:error, reason} ->
          Logger.error("Token refresh failed: #{inspect(reason)}")
          {:reply, {:error, reason}, state}
      end
    end

    @impl true
    def handle_info(:setup, state) do
      case setup() do
        {:ok, new_state} ->
          Logger.info("SMT Session Ready")
          {:noreply, Map.put(new_state, :resolved, true)}

        {:error, reason} ->
          Logger.error("Setup failed: #{inspect(reason)}. Retrying in 1 minute...")
          Process.send_after(self(), :setup, 60_000)
          {:noreply, state}
      end
    end

    # --- Private ---

    defp setup do
      with {:ok, token} <- load_or_authenticate() do
        discover_meters(token)
        {:ok, %{token: token}}
      end
    end

    defp discover_meters(token) do
      case SMTClient.get_meters(token, Config.smt_esiid()) do
        {:ok, meters} ->
          Enum.each(meters, fn m ->
            SmtInfluxSync.Meter.upsert(m.esiid, m.meter_number)
          end)
          Logger.info("[session] Discovered #{length(meters)} meters")
        {:error, reason} ->
          Logger.error("[session] Failed to discover meters: #{inspect(reason)}")
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
  end
end
