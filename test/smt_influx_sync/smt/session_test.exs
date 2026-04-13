defmodule SmtInfluxSync.SMT.SessionTest do
  use ExUnit.Case, async: false
  alias SmtInfluxSync.SMT.Session

  setup do
    bypass = Bypass.open()
    Application.put_env(:smt_influx_sync, :smt_auth_url, "http://localhost:#{bypass.port}/auth")
    Application.put_env(:smt_influx_sync, :smt_base_url, "http://localhost:#{bypass.port}")
    Application.put_env(:smt_influx_sync, :token_path, "/tmp/smt_token_test")
    Application.put_env(:smt_influx_sync, :smt_esiid, "*")
    Application.put_env(:smt_influx_sync, :smt_meter_number, "MN1")

    # DB ownership
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(SmtInfluxSync.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(SmtInfluxSync.Repo, {:shared, self()})

    # Clean up token path before each test
    File.rm("/tmp/smt_token_test")
    {:ok, bypass: bypass}
  end

  test "initializes and resolves session", %{bypass: bypass} do
    Bypass.expect(bypass, "POST", "/auth", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{token: "test_token"}))
    end)

    Bypass.expect(bypass, "POST", "/meter", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("content-type", "application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{data: [%{"esiid" => "123", "meterNumber" => "MN1"}]}))
    end)

    # Start the session manager with the expected name
    {:ok, pid} = Session.start_link([name: Session])
    
    # Wait for it to resolve
    # Poll for status
    await_resolved(attempts: 20)

    assert {:ok, %{token: "test_token", esiid: "123", meter_number: "MN1"}} == Session.get_credentials()
  end

  defp await_resolved(opts) do
    attempts = Keyword.get(opts, :attempts, 20)
    do_await_resolved(attempts)
  end

  defp do_await_resolved(0), do: flunk("Session did not resolve in time")
  defp do_await_resolved(attempts) do
    case Session.get_credentials() do
      {:ok, _} -> :ok
      {:error, :not_ready} ->
        Process.sleep(100)
        do_await_resolved(attempts - 1)
    end
  end
end
