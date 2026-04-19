defmodule SmtInfluxSync.Repo.Migrations.CreateSystemLogs do
  use Ecto.Migration

  def change do
    create table(:system_logs) do
      add :level, :string, null: false
      add :message, :text, null: false
      add :source, :string

      timestamps(updated_at: false)
    end

    create index(:system_logs, [:level])
    create index(:system_logs, [:inserted_at])
  end
end
