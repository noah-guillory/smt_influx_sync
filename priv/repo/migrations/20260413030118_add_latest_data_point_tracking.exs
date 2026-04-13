defmodule SmtInfluxSync.Repo.Migrations.AddLatestDataPointTracking do
  use Ecto.Migration

  def change do
    alter table(:sync_logs) do
      add :latest_data_point, :utc_datetime
    end

    alter table(:meters) do
      add :last_interval_at, :utc_datetime
      add :last_daily_at, :utc_datetime
      add :last_monthly_at, :utc_datetime
      add :last_odr_at, :utc_datetime
    end
  end
end
