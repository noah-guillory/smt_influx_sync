defmodule SmtInfluxSync.InfluxWriter do
  require Logger

  alias SmtInfluxSync.Config

  @doc """
  Writes a point to InfluxDB v2 using the line protocol.

  Tags and fields are maps with string or atom keys.
  Timestamp is Unix seconds (integer).
  """
  def write(measurement, tags, fields, timestamp_unix_s) do
    line = build_line(measurement, tags, fields, timestamp_unix_s)
    url = "#{Config.influx_url()}/api/v2/write"

    case Req.post(url,
           body: line,
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

  defp build_line(measurement, tags, fields, timestamp) do
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
