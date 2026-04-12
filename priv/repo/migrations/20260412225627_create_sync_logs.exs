defmodule SmtInfluxSync.Repo.Migrations.CreateSyncLogs do
  use Ecto.Migration

  def change do
    create table(:sync_logs) do
      add :source, :string, null: false
      add :status, :string, null: false # :start, :success, :fail
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :message, :text
      add :details, :map

      timestamps()
    end

    create index(:sync_logs, [:source])
    create index(:sync_logs, [:inserted_at])
  end
end
