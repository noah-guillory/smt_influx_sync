defmodule SmtInfluxSync.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        SmtInfluxSync.InfluxWriter
      ] ++
        if(Application.get_env(:smt_influx_sync, :start_workers, true),
          do: [SmtInfluxSync.Scheduler, SmtInfluxSync.YnabSyncWorker],
          else: []
        )

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: SmtInfluxSync.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
