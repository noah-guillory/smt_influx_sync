defmodule SmtInfluxSync.InfluxWriterTest do
  use ExUnit.Case, async: true
  alias SmtInfluxSync.InfluxWriter

  describe "build_line/4" do
    test "correctly formats simple measurement" do
      line = InfluxWriter.build_line("m", %{t: "v"}, %{f: 1.0}, 12345)
      assert line == "m,t=v f=1.0 12345"
    end

    test "escapes keys and values" do
      line = InfluxWriter.build_line("m 1", %{"t,1" => "v 2"}, %{"f=3" => "v\"4"}, 12345)
      # Measurement escapes spaces: m\ 1
      # Tag key escapes commas: t\,1
      # Tag value escapes spaces: v\ 2
      # Field key escapes =: f\=3
      # Field value escapes quotes: "v\"4"
      assert line == "m\\ 1,t\\,1=v\\ 2 f\\=3=\"v\\\"4\" 12345"
    end

    test "formats different field types" do
      line = InfluxWriter.build_line("m", %{}, %{f1: 1.0, f2: 42, f3: true}, 12345)
      assert line =~ "f1=1.0"
      assert line =~ "f2=42i"
      assert line =~ "f3=true"
    end
  end
end
