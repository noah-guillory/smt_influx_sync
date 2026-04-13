import Config

config :logger, level: :info

config :elixir, :time_zone_database, Tzdata.TimeZoneDatabase

config :smt_influx_sync,
  ecto_repos: [SmtInfluxSync.Repo]

# Phoenix configuration
config :smt_influx_sync, SmtInfluxSyncWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  server: true,
  render_errors: [
    formats: [html: SmtInfluxSyncWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: SmtInfluxSync.PubSub,
  live_view: [signing_salt: "SECRET_SALT_CHANGE_ME"]

config :smt_influx_sync, SmtInfluxSync.PubSub,
  adapter: Phoenix.PubSub.PG2

config :smt_influx_sync, Oban,
  repo: SmtInfluxSync.Repo,
  prefix: false,
  notifier: Oban.Notifiers.Isolated,
  peer: Oban.Peers.Isolated,
  plugins: [Oban.Plugins.Pruner],
  queues: [default: 10]

import_config "#{config_env()}.exs"
