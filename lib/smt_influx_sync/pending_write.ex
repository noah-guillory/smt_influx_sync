defmodule SmtInfluxSync.PendingWrite do
  use Ecto.Schema
  import Ecto.Changeset

  schema "pending_writes" do
    field :measurement, :string
    field :tags, :map
    field :fields, :map
    field :timestamp, :integer

    timestamps(type: :utc_datetime)
  end

  def changeset(pending_write, attrs) do
    pending_write
    |> cast(attrs, [:measurement, :tags, :fields, :timestamp])
    |> validate_required([:measurement, :tags, :fields, :timestamp])
  end
end
