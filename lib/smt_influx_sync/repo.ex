defmodule SmtInfluxSync.Repo do
  use Ecto.Repo,
    otp_app: :smt_influx_sync,
    adapter: Ecto.Adapters.SQLite3
end
