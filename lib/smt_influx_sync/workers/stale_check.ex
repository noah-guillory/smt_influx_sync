defmodule SmtInfluxSync.Workers.StaleCheck do
  @moduledoc """
  Periodic check for stale meters to send notifications.
  """
  use Oban.Worker, queue: :default, max_attempts: 1
  require Logger
  alias SmtInfluxSync.{Meter, Notifier}

  @impl Oban.Worker
  def perform(_job) do
    active_meters = Meter.list_active()
    now = DateTime.utc_now()
    threshold = 24 * 60 * 60 # 24 hours in seconds

    stale_meters = 
      Enum.filter(active_meters, fn meter ->
        # Check interval and daily data points
        is_stale?(meter.last_interval_at, now, threshold) and 
        is_stale?(meter.last_daily_at, now, threshold)
      end)

    if stale_meters != [] do
      meter_list = Enum.map(stale_meters, fn m -> "#{m.label || m.meter_number} (#{m.esiid})" end) |> Enum.join(", ")
      Notifier.notify("⚠️ SMT Alert: The following meters haven't synced new data in over 24 hours: #{meter_list}")
    end

    schedule_next()
    :ok
  end

  defp is_stale?(nil, _now, _threshold), do: true
  defp is_stale?(dt, now, threshold) do
    DateTime.diff(now, dt) > threshold
  end

  def schedule_next do
    # Run every 6 hours
    %{}
    |> __MODULE__.new(scheduled_at: DateTime.add(DateTime.utc_now(), 6, :hour))
    |> Oban.insert!()
  end
end
