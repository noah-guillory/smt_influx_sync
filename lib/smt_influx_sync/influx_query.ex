defmodule SmtInfluxSync.InfluxQuery do
  alias SmtInfluxSync.Config

  @sources %{
    "interval" => %{measurement: "electricity_interval", field: "consumption", window: "1d", granularity: :day},
    "daily" => %{measurement: "electricity_daily", field: "reading", window: "1d", granularity: :day},
    "monthly" => %{measurement: "electricity_monthly", field: "actl_kwh_usg", window: "1mo", granularity: :month}
  }

  @doc """
  Detects gaps in InfluxDB data for the given source over the last 24 months.

  Returns `{:ok, gaps}` where gaps is a list of `{start_date, end_date}` Date tuples
  representing contiguous ranges of missing days (or months for the monthly source),
  or `{:error, reason}` on failure.

  Only reports gaps between the first data point and yesterday (or last full month).
  """
  def detect_gaps(source) when is_map_key(@sources, source) do
    %{measurement: measurement, field: field, window: window, granularity: granularity} =
      @sources[source]

    query = build_query(measurement, field, window)

    case run_query(query) do
      {:ok, body} ->
        periods_with_data = parse_periods_with_data(body)
        {:ok, compute_gaps(periods_with_data, granularity)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_query(measurement, field, window) do
    """
    from(bucket: "#{Config.influx_bucket()}")
      |> range(start: -24mo)
      |> filter(fn: (r) => r._measurement == "#{measurement}")
      |> filter(fn: (r) => r._field == "#{field}")
      |> aggregateWindow(every: #{window}, fn: count, timeSrc: "_start")
      |> filter(fn: (r) => r._value > 0)
      |> keep(columns: ["_time"])
    """
  end

  defp run_query(query) do
    url = "#{Config.influx_url()}/api/v2/query"

    case Req.post(url,
           body: query,
           params: [org: Config.influx_org()],
           headers: [
             {"authorization", "Token #{Config.influx_token()}"},
             {"content-type", "application/vnd.flux"},
             {"accept", "application/csv"}
           ],
           retry: false,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: 401}} -> {:error, :unauthorized}
      {:ok, %{status: status, body: body}} -> {:error, {:influx_error, status, inspect(body)}}
      {:error, reason} -> {:error, {:http_error, reason}}
    end
  end

  # Parse the InfluxDB annotated CSV response to extract dates/months that have data.
  # With `timeSrc: "_start"`, _time is the window start (midnight UTC for daily,
  # first-of-month for monthly), so DateTime.to_date/1 gives the correct period.
  defp parse_periods_with_data(body) do
    lines = String.split(body, "\n")
    time_idx = find_time_column_index(lines)

    if time_idx do
      lines
      |> Enum.filter(&String.starts_with?(&1, ",,"))
      |> Enum.flat_map(fn line ->
        cols = String.split(line, ",")
        time_str = Enum.at(cols, time_idx, "")

        case DateTime.from_iso8601(time_str) do
          {:ok, dt, _} -> [DateTime.to_date(dt)]
          _ -> []
        end
      end)
      |> MapSet.new()
    else
      MapSet.new()
    end
  end

  # The header row in InfluxDB annotated CSV starts with ",result," and contains column names.
  defp find_time_column_index(lines) do
    lines
    |> Enum.find(&(String.starts_with?(&1, ",result,") and String.contains?(&1, "_time")))
    |> case do
      nil -> nil
      header -> Enum.find_index(String.split(header, ","), &(&1 == "_time"))
    end
  end

  defp compute_gaps(periods, granularity) do
    if MapSet.size(periods) == 0 do
      []
    else
      do_compute_gaps(periods, granularity)
    end
  end

  defp do_compute_gaps(periods, :day) do
    [first_day | _] = Enum.sort(periods, Date)
    yesterday = Date.add(Date.utc_today(), -1)

    if Date.compare(first_day, yesterday) == :gt do
      []
    else
      Date.range(first_day, yesterday)
      |> Enum.reject(&MapSet.member?(periods, &1))
      |> build_contiguous_day_ranges()
    end
  end

  defp do_compute_gaps(periods, :month) do
    [first_month | _] = Enum.sort(periods, Date)
    today = Date.utc_today()
    # Last complete month = first day of current month, go back one day, then to first of that month
    this_month_start = %Date{year: today.year, month: today.month, day: 1}
    prev_month_last = Date.add(this_month_start, -1)
    last_month_start = %Date{year: prev_month_last.year, month: prev_month_last.month, day: 1}

    if Date.compare(first_month, last_month_start) == :gt do
      []
    else
      months_in_range(first_month, last_month_start)
      |> Enum.reject(&MapSet.member?(periods, &1))
      |> Enum.map(fn month_start ->
        month_end = %Date{
          year: month_start.year,
          month: month_start.month,
          day: Date.days_in_month(month_start)
        }

        {month_start, month_end}
      end)
    end
  end

  # Generate a list of first-of-month dates from start_month through end_month (inclusive).
  defp months_in_range(start_month, end_month) do
    Stream.unfold(start_month, fn current ->
      if Date.compare(current, end_month) == :gt do
        nil
      else
        {current, advance_month(current)}
      end
    end)
    |> Enum.to_list()
  end

  defp advance_month(%Date{year: year, month: 12}), do: %Date{year: year + 1, month: 1, day: 1}
  defp advance_month(%Date{year: year, month: month}), do: %Date{year: year, month: month + 1, day: 1}

  # Convert a sorted list of dates into contiguous ranges [{start, end}, ...]
  defp build_contiguous_day_ranges([]), do: []

  defp build_contiguous_day_ranges(dates) do
    dates
    |> Enum.reduce([], fn date, acc ->
      case acc do
        [{start, last} | rest] ->
          if Date.diff(date, last) == 1 do
            [{start, date} | rest]
          else
            [{date, date} | acc]
          end

        [] ->
          [{date, date}]
      end
    end)
    |> Enum.reverse()
  end
end
