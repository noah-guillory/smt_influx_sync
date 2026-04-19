defmodule SmtInfluxSync.SyncMetadata do
  import Ecto.Query
  alias SmtInfluxSync.{Config, Repo, SyncLog}

  def log_start(source, message \\ nil) do
    log = %SyncLog{}
    |> SyncLog.changeset(%{
      source: source,
      status: "start",
      started_at: DateTime.utc_now(),
      message: message
    })
    |> Repo.insert!()

    broadcast(source, {:sync_started, log})
    log
  end

  def log_success(log, message \\ nil, details \\ nil, latest_data_point \\ nil, elapsed_ms \\ nil) do
    log = log
    |> SyncLog.changeset(%{
      status: "success",
      completed_at: DateTime.utc_now(),
      message: message,
      details: details,
      latest_data_point: latest_data_point,
      elapsed_ms: elapsed_ms
    })
    |> Repo.update!()

    broadcast(log.source, {:sync_completed, log})
    log
  end

  def log_fail(log, message \\ nil, details \\ nil) do
    log = log
    |> SyncLog.changeset(%{
      status: "fail",
      completed_at: DateTime.utc_now(),
      message: message,
      details: details
    })
    |> Repo.update!()

    broadcast(log.source, {:sync_failed, log})
    log
  end

  defp broadcast(source, event) do
    Phoenix.PubSub.broadcast(SmtInfluxSync.PubSub, "sync_events", event)
    Phoenix.PubSub.broadcast(SmtInfluxSync.PubSub, "sync_events:#{source}", event)
  end

  def get_latest_data_point(source) do
    SyncLog
    |> where([l], l.source == ^source and l.status == "success")
    |> where([l], not is_nil(l.latest_data_point))
    |> order_by([l], desc: l.latest_data_point)
    |> limit(1)
    |> select([l], l.latest_data_point)
    |> Repo.one()
  end

  def get_latest_sync(source) do
    SyncLog
    |> where([l], l.source == ^source and l.status == "success")
    |> order_by([l], desc: l.completed_at)
    |> limit(1)
    |> Repo.one()
  end

  def needs_initial_sync?(source, max_age_hours \\ 24) do
    case get_latest_sync(source) do
      nil -> true
      log ->
        threshold = DateTime.add(DateTime.utc_now(), -max_age_hours, :hour)
        DateTime.compare(log.completed_at, threshold) == :lt
    end
  end

  def list_recent_logs(limit \\ 20) do
    SyncLog
    |> order_by([l], desc: l.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Returns p50/p95/avg duration stats for successful syncs of a given source
  over the last `days` days. Returns nil if fewer than 2 samples exist.
  """
  def get_duration_stats(source, days \\ 7) do
    cutoff = DateTime.add(DateTime.utc_now(), -days * 24 * 60 * 60)

    values =
      SyncLog
      |> where([l], l.source == ^source and l.status == "success")
      |> where([l], not is_nil(l.elapsed_ms))
      |> where([l], l.completed_at >= ^cutoff)
      |> select([l], l.elapsed_ms)
      |> Repo.all()

    case length(values) do
      n when n < 2 ->
        nil

      n ->
        sorted = Enum.sort(values)
        avg = round(Enum.sum(sorted) / n)
        p50 = Enum.at(sorted, div(n, 2))
        p95 = Enum.at(sorted, min(trunc(n * 0.95), n - 1))
        %{avg: avg, p50: p50, p95: p95, count: n}
    end
  end

  def clear_all_sync_data do
    Repo.transaction(fn ->
      Repo.delete_all(SyncLog)
      Repo.update_all(SmtInfluxSync.Meter, set: [
        last_interval_at: nil,
        last_daily_at: nil,
        last_monthly_at: nil,
        last_odr_at: nil
      ])
      Repo.delete_all(SmtInfluxSync.PendingWrite)
      
      # Clear file-based caches if they exist
      Enum.each(~w(daily interval monthly odr ynab), fn source ->
        path = Config.last_sync_path(source)
        if File.exists?(path), do: File.rm(path)
      end)
      
      odr_count_path = Config.odr_daily_count_path()
      if File.exists?(odr_count_path), do: File.rm(odr_count_path)
    end)
  end
end
