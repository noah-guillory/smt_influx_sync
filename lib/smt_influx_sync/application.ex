defmodule SmtInfluxSync.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    # Run startup tasks (migrations and file migration)
    if Application.get_env(:smt_influx_sync, :run_migrations, true) do
      startup_tasks()
    end

    children =
      [
        SmtInfluxSync.Repo,
        SmtInfluxSync.ConfigManager
      ] ++
        (if Application.get_env(:smt_influx_sync, :oban_enabled, true),
          do: [{Oban, Application.fetch_env!(:smt_influx_sync, Oban)}],
          else: []
        ) ++
        [
          {Phoenix.PubSub, name: SmtInfluxSync.PubSub},
          SmtInfluxSyncWeb.Endpoint,
          SmtInfluxSyncWeb.Telemetry,
          SmtInfluxSync.InfluxWriter
        ] ++
        if(Application.get_env(:smt_influx_sync, :start_workers, true),
          do: [
            {SmtInfluxSync.SMT.Session, [name: SmtInfluxSync.SMT.Session]}
          ],
          else: []
        )

    # Add custom logger handler for real-time logs in UI
    :logger.add_handler(:smt_logs, SmtInfluxSync.LoggerHandler, %{
      level: :info,
      formatter: {:logger_formatter, %{}}
    })

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SmtInfluxSync.Supervisor]
    
    case Supervisor.start_link(children, opts) do
      {:ok, pid} ->
        # Run initial job enqueueing after start
        if Application.get_env(:smt_influx_sync, :oban_enabled, true) do
          enqueue_initial_jobs()
        end

        {:ok, pid}
      other -> other
    end
  end

  defp startup_tasks do
    Ecto.Migrator.with_repo(SmtInfluxSync.Repo, fn _repo ->
      Ecto.Migrator.run(SmtInfluxSync.Repo, :up, all: true)
      migrate_files_to_db()
    end)
  end

  defp enqueue_initial_jobs do
    jobs = [
      {"daily", SmtInfluxSync.Workers.Daily, 24},
      {"interval", SmtInfluxSync.Workers.Interval, 1},
      {"monthly", SmtInfluxSync.Workers.Monthly, 24},
      {"odr", SmtInfluxSync.Workers.ODR, 1},
      {"ynab", SmtInfluxSync.YnabSyncWorker, 24}
    ]

    Enum.each(jobs, fn {source, worker, max_age} ->
      if SmtInfluxSync.SyncMetadata.needs_initial_sync?(source, max_age) do
        %{} |> worker.new() |> Oban.insert!()
      else
        worker.schedule_next()
      end
    end)
  end

  defp migrate_files_to_db do
    # This function moves existing sync markers from flat files into the DB if they don't exist in DB yet.
    sources = ["daily", "interval", "monthly", "odr", "ynab"]
    data_dir = Application.get_env(:smt_influx_sync, :data_dir, "/data")

    Enum.each(sources, fn source ->
      path = Path.join(data_dir, "last_sync_#{source}")
      
      if File.exists?(path) do
        case SmtInfluxSync.SyncMetadata.get_latest_sync(source) do
          nil ->
            # DB is empty for this source, read file and migrate
            content = File.read!(path) |> String.trim()
            
            case parse_sync_marker(content) do
              {:ok, timestamp} ->
                # Log a success in DB with the historical date/time
                %SmtInfluxSync.SyncLog{}
                |> SmtInfluxSync.SyncLog.changeset(%{
                  source: source,
                  status: "success",
                  completed_at: timestamp,
                  message: "Migrated from flat file"
                })
                |> SmtInfluxSync.Repo.insert!()
                
                # Delete the old file to avoid re-migration
                File.rm(path)
                
              _ -> :ok
            end
          _ -> :ok
        end
      end
    end)
  end

  defp parse_sync_marker(content) do
    # Format 1: "YYYY-MM-DD"
    # Format 2: "YYYY-MM-DD HH:MM:SS TZ"
    case Date.from_iso8601(content) do
      {:ok, date} ->
        {:ok, DateTime.new!(date, ~T[00:00:00], SmtInfluxSync.Config.timezone())}
      _ ->
        case Regex.run(~r/^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})/, content) do
          [_, dt_part] ->
            naive = NaiveDateTime.from_iso8601!(dt_part)
            {:ok, DateTime.from_naive!(naive, SmtInfluxSync.Config.timezone())}
          _ -> :error
        end
    end
  end
end
