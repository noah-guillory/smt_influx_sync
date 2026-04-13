defmodule SmtInfluxSync.Workers.HelperTest do
  use ExUnit.Case, async: false
  alias SmtInfluxSync.Workers.Helper

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(SmtInfluxSync.Repo)
    Ecto.Adapters.SQL.Sandbox.mode(SmtInfluxSync.Repo, {:shared, self()})
    :ok
  end

  describe "parsing" do
    test "parse_12h_time/1" do
      assert {:ok, {0, 0}} == Helper.parse_12h_time(" 12:00 am")
      assert {:ok, {1, 15}} == Helper.parse_12h_time("1:15 am")
      assert {:ok, {12, 0}} == Helper.parse_12h_time("12:00 pm")
      assert {:ok, {13, 15}} == Helper.parse_12h_time("1:15 pm")
      assert :error == Helper.parse_12h_time("invalid")
    end

    test "parse_mdy_date/1" do
      # America/Chicago 2026-04-05 00:00:00 is CDT (-05:00)
      # 2026-04-05T00:00:00-05:00 = 1775365200
      assert {:ok, 1775365200} == Helper.parse_mdy_date("04/05/2026")
      assert :error == Helper.parse_mdy_date("2026-04-05")
    end

    test "parse_interval_timestamp/2" do
      # 2026-04-05 + 1:15 pm = 2026-04-05T13:15:00-05:00
      # 1775365200 (00:00) + 13*3600 + 15*60 = 1775412900
      assert {:ok, 1775412900} == Helper.parse_interval_timestamp("2026-04-05", "1:15 pm")
    end

    test "write_records/4 returns max timestamp" do
      records = [
        %{"date" => "2026-04-05", "starttime" => " 12:00 am", "consumption" => 0.1},
        %{"date" => "2026-04-05", "starttime" => " 1:00 am", "consumption" => 0.2}
      ]
      
      # 2026-04-05 1:00 am = 1775365200 (midnight) + 3600 = 1775368800
      {:ok, max_ts} = Helper.write_records("test", %{tag: "1"}, records, &Helper.parse_interval_record/1)
      assert max_ts == 1775368800
    end

    test "write_records/4 returns nil if no records" do
      assert {:ok, nil} == Helper.write_records("test", %{tag: "1"}, [], &Helper.parse_interval_record/1)
    end
  end
end
