defmodule SmtInfluxSync.Repo.Migrations.AddObanTables do
  use Ecto.Migration

  def up do
    Oban.Migration.up(version: 12)
  end

  # We specify `version: 1` in `down`, and Oban switches to taking only the
  # prefix into account and will downgrade to the specified version.
  def down do
    Oban.Migration.down(version: 1)
  end
end
