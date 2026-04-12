defmodule SmtInfluxSync.SMTClientTest do
  use ExUnit.Case, async: false
  alias SmtInfluxSync.SMTClient

  setup do
    bypass = Bypass.open()
    Application.put_env(:smt_influx_sync, :smt_auth_url, "http://localhost:#{bypass.port}/auth")
    Application.put_env(:smt_influx_sync, :smt_base_url, "http://localhost:#{bypass.port}")
    {:ok, bypass: bypass}
  end

  describe "pure functions" do
    test "parse_odr_date/1 parses valid date" do
      # America/Chicago: 2026-04-05 12:00:00 is CDT (-05:00)
      # 2026-04-05T12:00:00-05:00 = 1775408400
      assert {:ok, 1775408400} == SMTClient.parse_odr_date("04/05/2026 12:00:00")
    end

    test "parse_odr_date/1 returns error for invalid date" do
      assert :error == SMTClient.parse_odr_date("invalid")
      assert :error == SMTClient.parse_odr_date(nil)
    end

    test "format_date/1 formats Date correctly" do
      date = ~D[2026-04-05]
      assert "04/05/2026" == SMTClient.format_date(date)
    end
  end

  describe "HTTP interactions" do
    test "authenticate/2 success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/auth", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{token: "secret_token"}))
      end)

      assert {:ok, "secret_token"} == SMTClient.authenticate("user", "pass")
    end

    test "get_meters/2 success", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/meter", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: [%{"esiid" => "123", "meterNumber" => "MN1"}]}))
      end)

      assert {:ok, [%{esiid: "123", meter_number: "MN1"}]} == SMTClient.get_meters("token")
    end

    test "request_odr/3 rate limited", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/ondemandread", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: %{statusCode: "5031"}}))
      end)

      assert {:error, :rate_limited} == SMTClient.request_odr("token", "esiid", "mn")
    end

    test "request_odr/3 daily limit reached", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/ondemandread", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: %{statusCode: "5032", statusReason: "Limit reached"}}))
      end)

      assert {:error, :daily_limit_reached} == SMTClient.request_odr("token", "esiid", "mn")
    end

    test "request_odr/3 upstream timeout", %{bypass: bypass} do
      Bypass.expect_once(bypass, "POST", "/ondemandread", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{data: "upstream request timeout"}))
      end)

      assert {:error, :timeout} == SMTClient.request_odr("token", "esiid", "mn")
    end
  end
end
