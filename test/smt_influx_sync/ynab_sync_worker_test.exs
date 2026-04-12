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
    test "correctly parses valid flux csv with varying column order" do
      body = """
      #group,false,false,true,true,false,false,true,true,true,true
      #datatype,string,long,dateTime:RFC3339,dateTime:RFC3339,string,string,string,string,string,double
      #default,_result,,,,,,,,,
      ,result,table,_start,_stop,_field,_measurement,esiid,meter_number,source,_value
      ,_result,0,2025-03-13T05:28:23Z,2026-04-12T21:58:23Z,actl_kwh_usg,electricity_monthly,10443720009364021,136419480,monthly,1365.9166666666667\r
      """
      assert {:ok, 1365.9166666666667} == YnabSyncWorker.parse_flux_scalar(body)
    end

    test "returns error for empty response" do
      assert {:error, :no_data} == YnabSyncWorker.parse_flux_scalar("#header\n")
    end
  end

  # Integration tests using Bypass can be complex to set up because
  # the worker is a GenServer that triggers automatically.
  # For now, focus on the pure logic and a basic bypass test for the API call if needed.
end
