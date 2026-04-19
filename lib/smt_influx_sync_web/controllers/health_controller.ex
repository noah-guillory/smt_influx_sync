defmodule SmtInfluxSyncWeb.HealthController do
  use Phoenix.Controller, formats: [:json]

  alias SmtInfluxSync.{InfluxWriter, SyncMetadata}
  alias SmtInfluxSync.SMT.Session

  def index(conn, _params) do
    influx = InfluxWriter.get_status()
    session_ready = match?({:ok, _}, Session.get_token())

    last_sync =
      Enum.reduce(~w(daily interval monthly odr ynab), %{}, fn source, acc ->
        ts =
          case SyncMetadata.get_latest_sync(source) do
            nil -> nil
            log -> log.completed_at
          end

        Map.put(acc, source, ts)
      end)

    status =
      cond do
        not influx.healthy and influx.pending_count > 100 -> "unhealthy"
        not influx.healthy or not session_ready -> "degraded"
        true -> "ok"
      end

    http_status = if status == "ok", do: 200, else: 503

    conn
    |> put_status(http_status)
    |> json(%{
      status: status,
      influx_healthy: influx.healthy,
      influx_pending_writes: influx.pending_count,
      session_ready: session_ready,
      last_sync: last_sync
    })
  end
end
