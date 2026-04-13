defmodule SmtInfluxSync.ConfigManager do
  use GenServer
  require Logger

  @app :smt_influx_sync

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def update_config(updates) when is_map(updates) do
    GenServer.call(__MODULE__, {:update_config, updates})
  end

  def get_overrides do
    GenServer.call(__MODULE__, :get_overrides)
  end

  @impl true
  def init(_opts) do
    data_dir = Application.get_env(@app, :data_dir, "/data")
    # Ensure data directory exists immediately
    File.mkdir_p!(data_dir)
    
    overrides = load_overrides()
    
    # If no overrides exist yet, bootstrap the file with current environment values
    if overrides == %{} do
      bootstrap_overrides()
    else
      apply_overrides(overrides)
      {:ok, %{overrides: overrides}}
    end
  end

  defp bootstrap_overrides do
    initial_config = %{
      smt_username: Application.get_env(@app, :smt_username),
      smt_password: Application.get_env(@app, :smt_password),
      smt_esiid: Application.get_env(@app, :smt_esiid),
      smt_meter_number: Application.get_env(@app, :smt_meter_number),
      influx_url: Application.get_env(@app, :influx_url),
      influx_token: Application.get_env(@app, :influx_token),
      influx_org: Application.get_env(@app, :influx_org),
      influx_bucket: Application.get_env(@app, :influx_bucket),
      ynab_access_token: Application.get_env(@app, :ynab_access_token),
      ynab_budget_id: Application.get_env(@app, :ynab_budget_id),
      ynab_category_id: Application.get_env(@app, :ynab_category_id),
      kwh_rate: Application.get_env(@app, :kwh_rate),
      odr_sync_time: Application.get_env(@app, :odr_sync_time),
      interval_sync_time: Application.get_env(@app, :interval_sync_time),
      daily_sync_time: Application.get_env(@app, :daily_sync_time),
      monthly_sync_time: Application.get_env(@app, :monthly_sync_time),
      ynab_sync_time: Application.get_env(@app, :ynab_sync_time)
    }
    
    save_overrides(initial_config)
    {:ok, %{overrides: initial_config}}
  end

  @impl true
  def handle_call({:update_config, updates}, _from, state) do
    new_overrides = Map.merge(state.overrides, updates)
    save_overrides(new_overrides)
    apply_overrides(new_overrides)
    {:reply, :ok, %{state | overrides: new_overrides}}
  end

  @impl true
  def handle_call(:get_overrides, _from, state) do
    {:reply, state.overrides, state}
  end

  defp load_overrides do
    path = overrides_path()

    if File.exists?(path) do
      case File.read(path) do
        {:ok, content} ->
          case Jason.decode(content) do
            {:ok, data} -> 
              # Convert string keys to atoms for Application.put_env
              Map.new(data, fn {k, v} -> {String.to_atom(k), v} end)
            {:error, _} -> %{}
          end

        {:error, _} ->
          %{}
      end
    else
      %{}
    end
  end

  defp save_overrides(overrides) do
    path = overrides_path()
    File.mkdir_p!(Path.dirname(path))
    content = Jason.encode!(overrides)
    File.write!(path, content)
  end

  defp apply_overrides(overrides) do
    Enum.each(overrides, fn {key, value} ->
      Application.put_env(@app, key, value)
    end)
  end

  defp overrides_path do
    data_dir = Application.get_env(@app, :data_dir, "/data")
    Path.join(data_dir, "config_overrides.json")
  end
end
