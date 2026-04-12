defmodule SmtInfluxSync.Repo.Migrations.CreatePendingWrites do
  use Ecto.Migration

  def change do
    create table(:pending_writes) do
      add :measurement, :string, null: false
      add :tags, :map, null: false
      add :fields, :map, null: false
      add :timestamp, :bigint, null: false

      timestamps()
    end

    create index(:pending_writes, [:inserted_at])
  end
end
