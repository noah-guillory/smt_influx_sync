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
      {:bypass, "~> 2.1", only: :test}
    ]
  end
end
