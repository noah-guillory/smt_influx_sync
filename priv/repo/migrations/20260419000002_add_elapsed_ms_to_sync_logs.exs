defmodule SmtInfluxSync.Repo.Migrations.AddElapsedMsToSyncLogs do
  use Ecto.Migration

  def change do
    alter table(:sync_logs) do
      add :elapsed_ms, :integer
    end
  end
end
