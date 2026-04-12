defmodule SmtInfluxSync.YnabSyncWorkerTest do
  use ExUnit.Case, async: true
  alias SmtInfluxSync.YnabSyncWorker

  setup do
    bypass = Bypass.open()
    Application.put_env(:smt_influx_sync, :influx_url, "http://localhost:#{bypass.port}/influx")
    Application.put_env(:smt_influx_sync, :ynab_base_url, "http://localhost:#{bypass.port}/ynab")
    {:ok, bypass: bypass}
  end

  describe "parse_flux_scalar/1" do
    test "correctly parses valid flux csv" do
      body = """
      #group,false,false,true,true,false,false,true,true
      #datatype,string,long,dateTime:RFC3339,dateTime:RFC3339,double,string,string,string
      #default,_result,,,,,,,
      ,result,table,_start,_stop,_value,_field,_measurement,esiid
      ,,0,2025-03-12T00:00:00Z,2026-04-12T00:00:00Z,1050.5,actl_kwh_usg,electricity_monthly,12345
      """
      assert {:ok, 1050.5} == YnabSyncWorker.parse_flux_scalar(body)
    end

    test "returns error for empty response" do
      assert {:error, :no_data} == YnabSyncWorker.parse_flux_scalar("#header\n")
    end
  end

  # Integration tests using Bypass can be complex to set up because
  # the worker is a GenServer that triggers automatically.
  # For now, focus on the pure logic and a basic bypass test for the API call if needed.
end
