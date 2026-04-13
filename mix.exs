defmodule SmtInfluxSync.MixProject do
  use Mix.Project

  def project do
    [
      app: :smt_influx_sync,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger],
      mod: {SmtInfluxSync.Application, []}
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:req, "~> 0.5"},
      {:jason, "~> 1.4"},
      {:tzdata, "~> 1.1"},
      {:dotenv, "~> 3.0.0", only: [:dev, :test]},
      {:bypass, "~> 2.1", only: :test},
      {:phoenix, "~> 1.7"},
      {:phoenix_live_view, "~> 0.20"},
      {:phoenix_html, "~> 4.0"},
      {:phoenix_live_dashboard, "~> 0.8"},
      {:phoenix_pubsub, "~> 2.1"},
      {:telemetry_poller, "~> 1.0"},
      {:bandit, "~> 1.0"},
      {:ecto_sqlite3, "~> 0.17"},
      {:ecto, "~> 3.12"},
      {:oban, "~> 2.19"}
    ]
  end
end
