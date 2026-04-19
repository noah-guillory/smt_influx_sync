defmodule SmtInfluxSync.LoggerHandler do
  @moduledoc """
  A Logger handler that broadcasts log events to Phoenix.PubSub and persists
  them to the SQLite system_logs table.
  """

  def log(event, _config) do
    try do
      # event is a map with :level, :msg, :meta, :time
      %{level: level, msg: msg, meta: meta} = event

      # Format message
      formatted_msg = format_msg(msg)

      # Only handle logs from our app or those with worker metadata
      if meta[:application] == :smt_influx_sync or meta[:worker] != nil do
        source = meta[:worker] && to_string(meta[:worker])

        payload = %{
          level: level,
          message: formatted_msg,
          timestamp: format_time(event[:time]),
          meta: Map.take(meta, [:worker, :esiid])
        }

        # Broadcast via PubSub if available
        if Process.whereis(SmtInfluxSync.PubSub) do
          Phoenix.PubSub.broadcast(SmtInfluxSync.PubSub, "system_logs", {:log_event, payload})
        end

        # Persist to DB asynchronously
        if Process.whereis(SmtInfluxSync.Repo) do
          Task.start(fn ->
            %SmtInfluxSync.SystemLog{}
            |> SmtInfluxSync.SystemLog.changeset(%{
              level: to_string(level),
              message: formatted_msg,
              source: source
            })
            |> SmtInfluxSync.Repo.insert()

            # Prune ~2% of the time to keep the table at most 1000 entries
            if :rand.uniform(50) == 1 do
              SmtInfluxSync.SystemLog.prune_if_needed()
            end
          end)
        end
      end
    rescue
      _ -> :ok
    end
  end

  defp format_msg({:string, s}), do: List.to_string(s)
  defp format_msg({:report, r}), do: inspect(r)
  defp format_msg(msg) when is_binary(msg), do: msg
  defp format_msg(msg), do: inspect(msg)

  defp format_time(time) when is_integer(time) do
    # time is in microseconds since epoch in Elixir 1.15+
    DateTime.from_unix!(time, :microsecond)
    |> DateTime.shift_zone!(SmtInfluxSync.Config.timezone())
  rescue
    _ -> DateTime.utc_now()
  end

  defp format_time(_), do: DateTime.utc_now()
end
