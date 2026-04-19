defmodule SmtInfluxSync.SyncLog do
  use Ecto.Schema
  import Ecto.Changeset

  schema "sync_logs" do
    field :source, :string
    field :status, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :latest_data_point, :utc_datetime
    field :message, :string
    field :details, :map
    field :elapsed_ms, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(sync_log, attrs) do
    sync_log
    |> cast(attrs, [:source, :status, :started_at, :completed_at, :latest_data_point, :message, :details, :elapsed_ms])
    |> validate_required([:source, :status])
  end
end
