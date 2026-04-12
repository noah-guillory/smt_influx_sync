defmodule SmtInfluxSync.InfluxWriter do
  use GenServer
  require Logger
  import Ecto.Query

  alias SmtInfluxSync.{Config, Repo, PendingWrite}

  @retry_interval_ms 30_000
  @batch_size 5_000

  # --- Public API ---

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  @doc """
  Writes a single point to InfluxDB. If InfluxDB is healthy the write happens
  immediately; on failure (or while unhealthy) it is stored in SQLite and
  flushed once InfluxDB recovers.
  """
  def write(measurement, tags, fields, timestamp_unix_s) do
    GenServer.call(__MODULE__, {:write, measurement, tags, fields, timestamp_unix_s})
  end

  @doc """
  Writes a list of `{measurement, tags, fields, timestamp_unix_s}` tuples in
  batched HTTP requests (up to #{@batch_size} points per request).
  Failed chunks are queued to SQLite for retry.
  """
  def write_batch(entries) when is_list(entries) do
    GenServer.call(__MODULE__, {:write_batch, entries}, :infinity)
  end

  def pending_count do
    Repo.aggregate(PendingWrite, :count)
  end

  def get_status do
    GenServer.call(__MODULE__, :get_status)
  end

  # --- GenServer callbacks ---

  @impl true
  def init([]) do
    send(self(), :flush)
    schedule_flush()

    {:ok,
      %{
        healthy: true,
        last_write_at: nil,
        last_write_status: nil
      }}
  end

  @impl true
  def handle_call({:write, measurement, tags, fields, timestamp}, _from, state) do
    entry = {measurement, tags, fields, timestamp}

    if state.healthy and pending_count() == 0 do
      case do_write(entry) do
        :ok ->
          {:reply, :ok, update_state_success(state)}

        {:error, reason} ->
          Logger.warning("InfluxDB write failed (#{inspect(reason)}), queuing for retry")
          enqueue(entry)
          {:reply, :ok, update_state_fail(state, reason)}
      end
    else
      enqueue(entry)
      {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call({:write_batch, entries}, _from, state) do
    {state, ok} = do_write_batch(entries, state)
    {:reply, if(ok, do: :ok, else: {:error, :write_failed}), state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    status = %{
      healthy: state.healthy,
      pending_count: pending_count(),
      last_write_at: state.last_write_at,
      last_write_status: state.last_write_status
    }

    {:reply, status, state}
  end

  @impl true
  def handle_info(:flush, state) do
    state = flush_pending(state)
    schedule_flush()
    {:noreply, state}
  end

  # --- Private ---

  defp update_state_success(state) do
    %{state | healthy: true, last_write_at: DateTime.utc_now(), last_write_status: :ok}
  end

  defp update_state_fail(state, reason) do
    %{state | healthy: false, last_write_at: DateTime.utc_now(), last_write_status: {:error, reason}}
  end

  defp flush_pending(state) do
    query = from(p in PendingWrite, order_by: [asc: p.timestamp], limit: @batch_size)
    pending_chunk = Repo.all(query)

    if pending_chunk != [] do
      Logger.info("Flushing #{length(pending_chunk)} pending write(s) from SQLite")
      
      body =
        pending_chunk
        |> Enum.map(fn p -> build_line(p.measurement, p.tags, p.fields, p.timestamp) end)
        |> Enum.join("\n")

      case do_write_lines(body) do
        :ok ->
          ids = Enum.map(pending_chunk, & &1.id)
          from(p in PendingWrite, where: p.id in ^ids) |> Repo.delete_all()
          
          # Continue flushing if there's more
          if pending_count() > 0 do
            flush_pending(update_state_success(state))
          else
            update_state_success(state)
          end

        {:error, reason} ->
          Logger.warning(
            "InfluxDB still unhealthy during flush (#{inspect(reason)}), will retry in #{@retry_interval_ms}ms"
          )
          update_state_fail(state, reason)
      end
    else
      %{state | healthy: true}
    end
  end

  # Sends a list of entries in chunks, queuing any failed chunks to SQLite.
  defp do_write_batch(entries, state) do
    if state.healthy and pending_count() == 0 do
      entries
      |> Enum.chunk_every(@batch_size)
      |> Enum.reduce({state, true}, fn chunk, {acc_state, ok} ->
        if ok do
          body = chunk |> Enum.map(&build_line_from_entry/1) |> Enum.join("\n")

          case do_write_lines(body) do
            :ok ->
              {update_state_success(acc_state), true}

            {:error, reason} ->
              Logger.warning(
                "InfluxDB batch write failed (#{inspect(reason)}), queuing #{length(chunk)} records for retry"
              )

              Enum.each(chunk, &enqueue/1)
              {update_state_fail(acc_state, reason), false}
          end
        else
          Enum.each(chunk, &enqueue/1)
          {acc_state, false}
        end
      end)
    else
      Enum.each(entries, &enqueue/1)
      {state, true}
    end
  end

  defp do_write(entry) do
    do_write_lines(build_line_from_entry(entry))
  end

  defp do_write_lines(body) do
    url = "#{Config.influx_url()}/api/v2/write"

    case Req.post(url,
           body: body,
           params: [org: Config.influx_org(), bucket: Config.influx_bucket(), precision: "s"],
           headers: [
             {"authorization", "Token #{Config.influx_token()}"},
             {"content-type", "text/plain; charset=utf-8"}
           ],
           retry: false
         ) do
      {:ok, %{status: status}} when status in [200, 204] ->
        :ok

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status, body: body}} ->
        Logger.error("InfluxDB write failed: HTTP #{status} — #{inspect(body)}")
        {:error, {:influx_error, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp build_line_from_entry({measurement, tags, fields, timestamp}) do
    build_line(measurement, tags, fields, timestamp)
  end

  defp enqueue({measurement, tags, fields, timestamp}) do
    %PendingWrite{}
    |> PendingWrite.changeset(%{
      measurement: measurement,
      tags: tags,
      fields: fields,
      timestamp: timestamp
    })
    |> Repo.insert!()
  end

  defp schedule_flush, do: Process.send_after(self(), :flush, @retry_interval_ms)

  @doc false
  def build_line(measurement, tags, fields, timestamp) do
    tag_str =
      tags
      |> Enum.map(fn {k, v} -> "#{escape_key(k)}=#{escape_tag_value(v)}" end)
      |> Enum.join(",")

    field_str =
      fields
      |> Enum.map(fn {k, v} -> "#{escape_key(k)}=#{format_field_value(v)}" end)
      |> Enum.join(",")

    "#{escape_measurement(measurement)},#{tag_str} #{field_str} #{timestamp}"
  end

  defp escape_measurement(m), do: String.replace(to_string(m), [",", " "], &"\\#{&1}")
  defp escape_key(k), do: String.replace(to_string(k), [",", "=", " "], &"\\#{&1}")
  defp escape_tag_value(v), do: String.replace(to_string(v), [",", "=", " "], &"\\#{&1}")

  defp format_field_value(v) when is_float(v), do: "#{v}"
  defp format_field_value(v) when is_integer(v), do: "#{v}i"
  defp format_field_value(v) when is_boolean(v), do: "#{v}"

  defp format_field_value(v) when is_binary(v) do
    escaped = String.replace(v, ["\\", "\""], &"\\#{&1}")
    "\"#{escaped}\""
  end
end
