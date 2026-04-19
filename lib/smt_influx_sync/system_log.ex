defmodule SmtInfluxSync.SystemLog do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias SmtInfluxSync.Repo

  @max_entries 1_000

  schema "system_logs" do
    field :level, :string
    field :message, :string
    field :source, :string

    timestamps(updated_at: false)
  end

  def changeset(log, attrs) do
    log
    |> cast(attrs, [:level, :message, :source])
    |> validate_required([:level, :message])
  end

  @doc """
  Returns the most recent `limit` log entries, optionally filtered by level.
  """
  def list_recent(limit \\ 50, level_filter \\ nil) do
    __MODULE__
    |> maybe_filter_level(level_filter)
    |> order_by([l], desc: l.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Prunes entries beyond the @max_entries cap. Called probabilistically after inserts.
  """
  def prune_if_needed do
    count = Repo.aggregate(__MODULE__, :count)

    if count > @max_entries do
      keep_ids =
        from(l in __MODULE__, order_by: [desc: l.inserted_at], limit: @max_entries, select: l.id)
        |> Repo.all()

      from(l in __MODULE__, where: l.id not in ^keep_ids)
      |> Repo.delete_all()
    end
  end

  defp maybe_filter_level(query, nil), do: query
  defp maybe_filter_level(query, "all"), do: query
  defp maybe_filter_level(query, level), do: where(query, [l], l.level == ^level)
end
