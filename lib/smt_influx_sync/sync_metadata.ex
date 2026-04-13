defmodule SmtInfluxSync.SyncMetadata do
  import Ecto.Query
  alias SmtInfluxSync.{Repo, SyncLog}

  def log_start(source, message \\ nil) do
    %SyncLog{}
    |> SyncLog.changeset(%{
      source: source,
      status: "start",
      started_at: DateTime.utc_now(),
      message: message
    })
    |> Repo.insert!()
  end

  def log_success(log, message \\ nil, details \\ nil, latest_data_point \\ nil) do
    log
    |> SyncLog.changeset(%{
      status: "success",
      completed_at: DateTime.utc_now(),
      message: message,
      details: details,
      latest_data_point: latest_data_point
    })
    |> Repo.update!()
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

  def log_fail(log, message \\ nil, details \\ nil) do
    log
    |> SyncLog.changeset(%{
      status: "fail",
      completed_at: DateTime.utc_now(),
      message: message,
      details: details
    })
    |> Repo.update!()
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
end
