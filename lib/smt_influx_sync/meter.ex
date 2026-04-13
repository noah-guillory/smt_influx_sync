defmodule SmtInfluxSync.Meter do
  use Ecto.Schema
  import Ecto.Changeset

  schema "meters" do
    field :esiid, :string
    field :meter_number, :string
    field :is_active, :boolean, default: true
    field :label, :string

    timestamps()
  end

  def changeset(meter, attrs) do
    meter
    |> cast(attrs, [:esiid, :meter_number, :is_active, :label])
    |> validate_required([:esiid, :meter_number])
    |> unique_constraint(:esiid)
  end

  def list_active do
    import Ecto.Query
    SmtInfluxSync.Repo.all(from m in __MODULE__, where: m.is_active == true)
  end

  def list_all do
    SmtInfluxSync.Repo.all(__MODULE__)
  end

  def upsert(esiid, meter_number) do
    case SmtInfluxSync.Repo.get_by(__MODULE__, esiid: esiid) do
      nil ->
        %__MODULE__{}
        |> changeset(%{esiid: esiid, meter_number: meter_number})
        |> SmtInfluxSync.Repo.insert()
      meter ->
        {:ok, meter}
    end
  end

  def toggle_active(id) do
    meter = SmtInfluxSync.Repo.get!(__MODULE__, id)
    meter
    |> changeset(%{is_active: !meter.is_active})
    |> SmtInfluxSync.Repo.update()
  end

  def update_label(id, label) do
    meter = SmtInfluxSync.Repo.get!(__MODULE__, id)
    meter
    |> changeset(%{label: label})
    |> SmtInfluxSync.Repo.update()
  end
end
