defmodule SmtInfluxSync.Repo.Migrations.CreateMeters do
  use Ecto.Migration

  def change do
    create table(:meters) do
      add :esiid, :string, null: false
      add :meter_number, :string, null: false
      add :is_active, :boolean, default: true, null: false
      add :label, :string

      timestamps()
    end

    create unique_index(:meters, [:esiid])
  end
end
