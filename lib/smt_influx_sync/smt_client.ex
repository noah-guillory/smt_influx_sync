defmodule SmtInfluxSync.SMTClient do
  require Logger

  @base_url "https://smartmetertexas.com/api"

  @doc """
  Authenticates with Smart Meter Texas and returns a Bearer token.
  """
  def authenticate(username, password) do
    case Req.post("#{@base_url}/user/authenticate",
           json: %{username: username, password: password, rememberMe: false},
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"token" => token}}} ->
        {:ok, token}

      {:ok, %{status: 400, body: %{"errormessage" => msg}}} ->
        {:error, {:auth_failed, msg}}

      {:ok, %{status: status}} ->
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

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: status}} ->
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

      {:ok, %{status: 401}} ->
        {:error, :unauthorized}

      {:ok, %{status: 200, body: %{"data" => %{"statusCode" => code, "statusReason" => reason}}}} ->
        {:error, {:odr_failed, code, reason}}

      {:ok, %{status: status}} ->
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
        Logger.debug("ODR pending, #{attempts - 1} attempts remaining")
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
    Req.post("#{@base_url}#{path}",
      json: body,
      headers: [{"authorization", "Bearer #{token}"}],
      retry: false
    )
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
