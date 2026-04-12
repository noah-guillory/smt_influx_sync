defmodule SmtInfluxSync.SyncLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sync_logs" do
    field :source, :string
    field :status, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :message, :string
    field :details, :map

    timestamps()
  end

  def changeset(sync_log, attrs) do
    sync_log
    |> cast(attrs, [:source, :status, :started_at, :completed_at, :message, :details])
    |> validate_required([:source, :status])
  end
end
