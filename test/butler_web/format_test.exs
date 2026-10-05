defmodule ButlerWeb.FormatTest do
  use ExUnit.Case, async: true

  alias ButlerWeb.Format

  describe "duration/1" do
    test "formats seconds, minutes and hours" do
      assert Format.duration(0) == "0s"
      assert Format.duration(42) == "42s"
      assert Format.duration(60) == "1m 00s"
      assert Format.duration(330) == "5m 30s"
      assert Format.duration(3_600) == "1h 00m"
      assert Format.duration(7_500) == "2h 05m"
    end

    test "formats a missing duration as a dash" do
      assert Format.duration(nil) == "—"
    end
  end

  describe "datetime/1" do
    test "formats in UTC to the second" do
      assert Format.datetime(~U[2026-01-02 03:04:05.678Z]) == "2026-01-02 03:04:05 UTC"
      assert Format.datetime(nil) == "—"
    end
  end

  describe "ago/2" do
    test "formats a relative time" do
      now = ~U[2026-01-01 12:00:00Z]
      assert Format.ago(~U[2026-01-01 11:59:30Z], now) == "30s ago"
      assert Format.ago(~U[2026-01-01 11:00:00Z], now) == "1h 00m ago"
      assert Format.ago(nil, now) == "—"
    end
  end
end
