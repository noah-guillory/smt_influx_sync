defmodule SmtInfluxSyncTest do
  use ExUnit.Case
  doctest SmtInfluxSync

  test "greets the world" do
    assert SmtInfluxSync.hello() == :world
  end
end
