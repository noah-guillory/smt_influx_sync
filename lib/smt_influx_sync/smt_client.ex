defmodule SmtInfluxSync.SMTClient do
  require Logger

  @base_url "https://www.smartmetertexas.com/api"
  @user_agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/134.0.0.0 Safari/537.36"

  @doc """
  Authenticates with Smart Meter Texas and returns a Bearer token.
  """
  def authenticate(username, password) do
    url = "https://www.smartmetertexas.com/commonapi/user/authenticate"
    req_headers = [{"content-type", "application/json"}, {"user-agent", @user_agent}]

    Logger.debug(
      "SMT POST #{url}\n  req headers: #{inspect(req_headers)}\n  req body: %{username: \"#{username}\", password: \"[REDACTED]\", rememberMe: true}"
    )

    result =
      Req.post(url,
        json: %{username: username, password: password, rememberMe: true},
        headers: [{"user-agent", @user_agent}],
        redirect_trusted: true,
        retry: false
      )

    log_result(result)

    case result do
      {:ok, %{status: 200, body: %{"token" => token}}} ->
        {:ok, token}

      {:ok, %{status: 400, body: %{"errormessage" => msg}}} ->
        {:error, {:auth_failed, msg}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("SMT authenticate unexpected status #{status}: #{inspect(body)}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Fetches all meters for the account. Pass esiid: "*" to get all.
  Returns a list of maps with :esiid and :meter_number keys.
  """
  def get_meters(token, esiid \\ "*") do
    case authed_post(token, "/meter", %{ESIID: esiid}) do
      {:ok, %{status: 200, body: %{"data" => meters}}} when is_list(meters) ->
        parsed =
          Enum.map(meters, fn m ->
            %{esiid: m["esiid"], meter_number: m["meterNumber"]}
          end)

        {:ok, parsed}

      {:ok, %{status: 401, body: body}} ->
        Logger.error("SMT get_meters 401: #{inspect(body)}")
        {:error, :unauthorized}

      {:ok, %{status: status, body: body}} ->
        Logger.error("SMT get_meters unexpected status #{status}: #{inspect(body)}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Submits an on-demand read request for the given ESIID and meter number.
  """
  def request_odr(token, esiid, meter_number) do
    case authed_post(token, "/ondemandread", %{ESIID: esiid, MeterNumber: meter_number}) do
      {:ok, %{status: 200, body: %{"data" => %{"statusCode" => "0"}}}} ->
        :ok

      {:ok, %{status: 200, body: %{"data" => %{"statusCode" => "5031"}}}} ->
        {:error, :rate_limited}

      {:ok, %{status: 401, body: body}} ->
        Logger.error("SMT request_odr 401: #{inspect(body)}")
        {:error, :unauthorized}

      {:ok, %{status: 200, body: %{"data" => %{"statusCode" => code, "statusReason" => reason}}}} ->
        {:error, {:odr_failed, code, reason}}

      {:ok, %{status: status, body: body}} ->
        Logger.error("SMT request_odr unexpected status #{status}: #{inspect(body)}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Fetches the most recent ODR result without polling.
  Returns {:ok, reading} if a COMPLETED read exists, {:ok, :no_data} if
  the status is PENDING or the response contains no useful data, or
  {:error, reason} on failure.
  """
  def get_latest_read(token, esiid) do
    case authed_post(token, "/usage/latestodrread", %{ESIID: esiid}) do
      {:ok, %{status: 200, body: %{"data" => %{"odrstatus" => "COMPLETED"} = data}}} ->
        {:ok,
         %{
           value: parse_float(data["odrread"]),
           usage: parse_float(data["odrusage"]),
           date: data["odrdate"]
         }}

      {:ok, %{status: 200, body: %{"data" => %{"odrstatus" => "PENDING"}}}} ->
        {:ok, :no_data}

      {:ok, %{status: 200}} ->
        {:ok, :no_data}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status, body: body}} ->
        Logger.error("SMT get_latest_read unexpected status #{status}: #{inspect(body)}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Polls /usage/latestodrread until the read is COMPLETED.
  Returns {:ok, %{value, usage, date}} or {:error, reason}.
  """
  def poll_odr(token, esiid, attempts_remaining \\ nil) do
    max = attempts_remaining || SmtInfluxSync.Config.poll_max_attempts()
    do_poll_odr(token, esiid, max)
  end

  defp do_poll_odr(_token, _esiid, 0), do: {:error, :timeout}

  defp do_poll_odr(token, esiid, attempts) do
    case authed_post(token, "/usage/latestodrread", %{ESIID: esiid}) do
      {:ok, %{status: 200, body: %{"data" => %{"odrstatus" => "COMPLETED"} = data}}} ->
        {:ok,
         %{
           value: parse_float(data["odrread"]),
           usage: parse_float(data["odrusage"]),
           date: data["odrdate"]
         }}

      {:ok, %{status: 200, body: %{"data" => %{"odrstatus" => "PENDING"}}}} ->
        interval_s = div(SmtInfluxSync.Config.poll_interval_ms(), 1000)

        Logger.info(
          "[sync] ODR still pending, retrying in #{interval_s}s (#{attempts - 1} attempts left)"
        )

        Process.sleep(SmtInfluxSync.Config.poll_interval_ms())
        do_poll_odr(token, esiid, attempts - 1)

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  defp authed_post(token, path, body) do
    url = "#{@base_url}#{path}"

    req_headers = [
      {"authorization", "Bearer [REDACTED]"},
      {"content-type", "application/json"},
      {"user-agent", @user_agent}
    ]

    Logger.debug(
      "SMT POST #{url}\n  req headers: #{inspect(req_headers)}\n  req body: #{inspect(body)}"
    )

    result =
      Req.post(url,
        json: body,
        headers: [{"authorization", "Bearer #{token}"}, {"user-agent", @user_agent}],
        redirect_trusted: true,
        retry: false,
        receive_timeout: SmtInfluxSync.Config.smt_request_timeout_ms()
      )

    log_result(result)
    result
  end

  defp log_result({:ok, %{status: status, headers: headers, body: body}}) do
    Logger.debug(
      "SMT response status=#{status}\n  resp headers: #{inspect(headers)}\n  resp body: #{inspect(body)}"
    )
  end

  defp log_result({:error, reason}) do
    Logger.debug("SMT request error: #{inspect(reason)}")
  end

  @doc """
  Parses an SMT odrdate string ("MM/DD/YYYY HH:MM:SS") into a Unix timestamp (seconds).
  Returns {:ok, unix_seconds} or :error.
  """
  def parse_odr_date(nil), do: :error

  def parse_odr_date(date_str) when is_binary(date_str) do
    case Regex.run(~r/^(\d{2})\/(\d{2})\/(\d{4}) (\d{2}):(\d{2}):(\d{2})$/, date_str) do
      [_, mo, d, y, h, mi, s] ->
        case NaiveDateTime.new(
               String.to_integer(y),
               String.to_integer(mo),
               String.to_integer(d),
               String.to_integer(h),
               String.to_integer(mi),
               String.to_integer(s)
             ) do
          {:ok, ndt} ->
            case DateTime.from_naive(ndt, SmtInfluxSync.Config.timezone()) do
              {:ok, dt} -> {:ok, DateTime.to_unix(dt)}
              {:ambiguous, dt, _} -> {:ok, DateTime.to_unix(dt)}
              {:gap, _, dt} -> {:ok, DateTime.to_unix(dt)}
              {:error, _} -> :error
            end

          _ ->
            :error
        end

      _ ->
        :error
    end
  end

  @doc """
  Fetches 15-minute interval reads for the given date range.
  Returns {:ok, list} where each item is a raw map from the API.
  """
  def get_interval_data(token, esiid, start_date, end_date) do
    body = %{esiid: esiid, startDate: format_date(start_date), endDate: format_date(end_date)}

    case authed_post(token, "/usage/interval", body) do
      {:ok, %{status: 200, body: %{"intervaldata" => data}}} ->
        {:ok, List.wrap(data)}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status, body: body}} ->
        Logger.error("SMT get_interval_data unexpected status #{status}: #{inspect(body)}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Fetches daily usage for the given date range.
  Returns {:ok, list} where each item is a raw map from the API.
  """
  def get_daily_data(token, esiid, start_date, end_date) do
    body = %{esiid: esiid, startDate: format_date(start_date), endDate: format_date(end_date)}

    case authed_post(token, "/usage/daily", body) do
      {:ok, %{status: 200, body: %{"dailyData" => data}}} ->
        {:ok, List.wrap(data)}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status, body: body}} ->
        Logger.error("SMT get_daily_data unexpected status #{status}: #{inspect(body)}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Fetches monthly usage for the given date range.
  Returns {:ok, list} where each item is a raw map from the API.
  """
  def get_monthly_data(token, esiid, start_date, end_date) do
    body = %{esiid: esiid, startDate: format_date(start_date), endDate: format_date(end_date)}

    case authed_post(token, "/usage/monthly", body) do
      {:ok, %{status: 200, body: %{"monthlyData" => data}}} ->
        {:ok, List.wrap(data)}

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status, body: body}} ->
        Logger.error("SMT get_monthly_data unexpected status #{status}: #{inspect(body)}")
        {:error, {:unexpected_status, status}}

      {:error, reason} ->
        {:error, {:http_error, reason}}
    end
  end

  @doc """
  Formats an Elixir Date as "MM/DD/YYYY" for SMT API requests.
  """
  def format_date(%Date{} = date) do
    Calendar.strftime(date, "%m/%d/%Y")
  end

  defp parse_float(nil), do: nil
  defp parse_float(v) when is_float(v), do: v
  defp parse_float(v) when is_integer(v), do: v / 1.0

  defp parse_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> nil
    end
  end
end
