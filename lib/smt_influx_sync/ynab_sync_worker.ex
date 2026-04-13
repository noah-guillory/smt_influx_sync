defmodule SmtInfluxSync.YnabSyncWorker do
  @moduledoc """
  Oban worker for YNAB budget target sync.
  """
  use Oban.Worker, queue: :default, max_attempts: 3
  require Logger

  alias SmtInfluxSync.Config

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    Logger.info("[ynab] Starting sync")
    sync_log = SmtInfluxSync.SyncMetadata.log_start("ynab")
    ping_healthcheck(:start)
    started_at = System.monotonic_time(:millisecond)

    with {:ok, average_kwh} <- fetch_trailing_average(),
         :ok <- update_ynab_target(average_kwh) do
      elapsed_ms = System.monotonic_time(:millisecond) - started_at
      Logger.info("[ynab] Sync completed successfully in #{elapsed_ms}ms")
      SmtInfluxSync.SyncMetadata.log_success(sync_log, "Sync completed in #{elapsed_ms}ms")
      SmtInfluxSync.Workers.Helper.save_last_sync_now("ynab")
      ping_healthcheck(:success)
      schedule_next()
      :ok
    else
      {:error, reason} ->
        elapsed_ms = System.monotonic_time(:millisecond) - started_at
        Logger.error("[ynab] Sync failed in #{elapsed_ms}ms: #{inspect(reason)}")
        SmtInfluxSync.SyncMetadata.log_fail(sync_log, "Sync failed: #{inspect(reason)}")
        ping_healthcheck(:fail)
        schedule_next()
        {:error, reason}
    end
  end

  def schedule_next do
    {h, m} = Config.parse_time_string(Config.ynab_sync_time())
    ms = SmtInfluxSync.Workers.Helper.ms_until_next_time(h, m)
    
    %{}
    |> __MODULE__.new(scheduled_at: DateTime.add(DateTime.utc_now(), ms, :millisecond))
    |> Oban.insert!()
  end

  # --- Private ---

  defp fetch_trailing_average do
    url = "#{Config.influx_url()}/api/v2/query?org=#{Config.influx_org()}"

    flux_query = """
    from(bucket: "#{Config.influx_bucket()}")
      |> range(start: -13mo)
      |> filter(fn: (r) => r._measurement == "electricity_monthly" and r._field == "actl_kwh_usg")
      |> group(columns: ["_time"])
      |> sum()
      |> group()
      |> tail(n: 12)
      |> sum()
      |> map(fn: (r) => ({r with _value: r._value / 12.0}))
    """

    case Req.post(url,
           body: flux_query,
           headers: [
             {"authorization", "Token #{Config.influx_token()}"},
             {"accept", "application/csv"},
             {"content-type", "application/vnd.flux"}
           ],
           retry: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        parse_flux_scalar(body)

      {:ok, %{status: status, body: body}} ->
        {:error, {:influx_query_failed, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc false
  # Parses a single scalar value out of a Flux CSV response.
  def parse_flux_scalar(body) do
    lines =
      body
      |> String.split(~r/\r?\n/, trim: true)
      |> Enum.reject(&String.starts_with?(&1, "#"))

    case lines do
      [header, data_row | _] ->
        header_cols = String.split(header, ",")
        data_cols = String.split(data_row, ",")

        case Enum.find_index(header_cols, &(&1 == "_value")) do
          nil ->
            {:error, :value_column_not_found}

          idx ->
            value_str = Enum.at(data_cols, idx) |> String.trim()

            case Float.parse(value_str) do
              {f, _} -> {:ok, f}
              :error -> {:error, {:parse_error, data_row}}
            end
        end

      _ ->
        {:error, :no_data}
    end
  end

  defp update_ynab_target(average_kwh) do
    tiers_str = Config.kwh_tiers()
    base_rate = Config.kwh_rate()
    target = calculate_cost(average_kwh, tiers_str, base_rate)
    goal_target_milliunits = trunc(target * 1000)
    
    # Get local time for a more useful timestamp
    now = DateTime.now!(Config.timezone())
    timestamp = Calendar.strftime(now, "%Y-%m-%d %H:%M:%S %Z")
    
    rate_str = :erlang.float_to_binary(base_rate, decimals: 3)
    avg_kwh_str = :erlang.float_to_binary(average_kwh, decimals: 2)
    target_str = :erlang.float_to_binary(target, decimals: 2)

    note_base = """
    Last sync: #{timestamp}
    Calculated Target: $#{target_str}
    Trailing 12-month average: #{avg_kwh_str} kWh/mo
    """ |> String.trim()

    note =
      if tiers_str != "" do
        note_base <> "\nConfigured Tiers: #{tiers_str}"
      else
        note_base <> "\nConfigured Rate: $#{rate_str}/kWh"
      end

    Logger.info(
      "[ynab] Setting budget target to $#{target_str} " <>
        "(#{avg_kwh_str} kWh, tiers: #{if tiers_str != "", do: tiers_str, else: rate_str})"
    )

    url =
      "#{Config.ynab_base_url()}/v1/budgets/#{Config.ynab_budget_id()}/categories/#{Config.ynab_category_id()}"

    case Req.patch(url,
           json: %{category: %{goal_target: goal_target_milliunits, note: note}},
           headers: [{"authorization", "Bearer #{Config.ynab_access_token()}"}],
           retry: false
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        Logger.info("[ynab] YNAB category updated successfully")
        :ok

      {:ok, %{status: status, body: body}} ->
        {:error, {:ynab_api_failed, status, body}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp calculate_cost(kwh, tiers, base_rate) when is_list(tiers) do
    # Filter out empty/invalid tiers and sort by limit
    parsed_tiers = 
      tiers
      |> Enum.map(fn
        %{"limit" => l, "rate" => r} -> {parse_float_safe(l), parse_float_safe(r)}
        %{limit: l, rate: r} -> {parse_float_safe(l), parse_float_safe(r)}
        _ -> nil
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn {limit, _} -> limit end)

    calculate_cumulative(kwh, parsed_tiers, base_rate)
  end

  defp calculate_cost(kwh, tiers_str, base_rate) when is_binary(tiers_str) do
    tiers_str = String.trim(tiers_str)
    
    if tiers_str == "" do
      kwh * base_rate
    else
      try do
        # Format: limit1:rate1,limit2:rate2,...,final_rate
        # Example: 1000:0.10,0.15
        parts = String.split(tiers_str, ",")
        
        {tiers, default_rate} = 
          case List.last(parts) do
            last when is_binary(last) ->
              if String.contains?(last, ":") do
                {parts, base_rate}
              else
                {Enum.slice(parts, 0..-2//1), parse_float_safe(last)}
              end
            _ -> {[], base_rate}
          end

        parsed_tiers = 
          tiers
          |> Enum.map(fn t ->
            [limit, rate] = String.split(t, ":")
            {parse_float_safe(limit), parse_float_safe(rate)}
          end)
          |> Enum.sort_by(fn {limit, _} -> limit end)

        calculate_cumulative(kwh, parsed_tiers, default_rate)
      rescue
        e ->
          Logger.error("[ynab] Failed to parse tiered pricing string, falling back to base rate: #{inspect(e)}")
          kwh * base_rate
      end
    end
  end

  defp calculate_cost(kwh, _, base_rate), do: kwh * base_rate

  defp parse_float_safe(v) when is_number(v), do: v / 1.0
  defp parse_float_safe(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 
        case Integer.parse(v) do
          {i, _} -> i / 1.0
          :error -> 0.0
        end
    end
  end
  defp parse_float_safe(_), do: 0.0

  defp calculate_cumulative(kwh, tiers, default_rate) do
    {total_cost, last_limit} =
      Enum.reduce(tiers, {0.0, 0.0}, fn {limit, rate}, {cost, prev_limit} ->
        applicable_kwh = 
          cond do
            kwh <= prev_limit -> 0.0
            kwh <= limit -> kwh - prev_limit
            true -> limit - prev_limit
          end
        {cost + (applicable_kwh * rate), limit}
      end)

    if kwh > last_limit do
      total_cost + ((kwh - last_limit) * default_rate)
    else
      total_cost
    end
  end

  defp ping_healthcheck(signal) do
    case Config.ynab_healthchecks_ping_url() do
      nil ->
        :ok

      base_url ->
        url =
          case signal do
            :start -> "#{base_url}/start"
            :success -> base_url
            :fail -> "#{base_url}/fail"
          end

        case Req.get(url, retry: false) do
          {:ok, %{status: status}} when status in 200..299 ->
            Logger.debug("[ynab] [healthchecks] Pinged #{signal}")

          {:ok, %{status: status}} ->
            Logger.warning("[ynab] [healthchecks] Ping #{signal} returned HTTP #{status}")

          {:error, reason} ->
            Logger.warning("[ynab] [healthchecks] Ping #{signal} failed: #{inspect(reason)}")
        end
    end
  end
end
