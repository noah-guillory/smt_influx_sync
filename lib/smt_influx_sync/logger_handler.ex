defmodule SmtInfluxSync.LoggerHandler do
  @moduledoc """
  A Logger handler that broadcasts log events to Phoenix.PubSub.
  """

  def log(event, _config) do
    try do
      # event is a map with :level, :msg, :meta, :time
      %{level: level, msg: msg, meta: meta, time: time} = event
      
      # Format message
      formatted_msg = format_msg(msg)
      
      # Broadcast if it's from our app
      if meta[:application] == :smt_influx_sync or meta[:worker] != nil do
        payload = %{
          level: level,
          message: formatted_msg,
          timestamp: format_time(time),
          meta: Map.take(meta, [:worker, :esiid])
        }
        
        # Check if PubSub is running before broadcasting
        if Process.whereis(SmtInfluxSync.PubSub) do
          Phoenix.PubSub.broadcast(SmtInfluxSync.PubSub, "system_logs", {:log_event, payload})
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
