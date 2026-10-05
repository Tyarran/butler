defmodule ButlerWeb.Format do
  @moduledoc """
  Formatting helpers for durations and timestamps shown in the UI.
  """

  @none "—"
  @minute 60
  @hour 3_600

  @doc "Formats a number of seconds, like 5m 30s or 2h 05m; a dash for `nil`."
  @spec duration(non_neg_integer() | nil) :: String.t()
  def duration(nil), do: @none
  def duration(seconds) when seconds < @minute, do: "#{seconds}s"

  def duration(seconds) when seconds < @hour do
    "#{div(seconds, @minute)}m #{pad(rem(seconds, @minute))}s"
  end

  def duration(seconds) do
    "#{div(seconds, @hour)}h #{pad(div(rem(seconds, @hour), @minute))}m"
  end

  @doc "Formats a `DateTime` in UTC to the second; a dash for `nil`."
  @spec datetime(DateTime.t() | nil) :: String.t()
  def datetime(nil), do: @none

  def datetime(%DateTime{} = datetime) do
    datetime |> DateTime.truncate(:second) |> Calendar.strftime("%Y-%m-%d %H:%M:%S UTC")
  end

  @doc "Formats the time elapsed since `datetime`, like 30s ago."
  @spec ago(DateTime.t() | nil, DateTime.t()) :: String.t()
  def ago(datetime, now \\ DateTime.utc_now())
  def ago(nil, _now), do: @none

  def ago(%DateTime{} = datetime, now) do
    seconds = max(DateTime.diff(now, datetime, :second), 0)
    duration(seconds) <> " ago"
  end

  defp pad(number), do: number |> Integer.to_string() |> String.pad_leading(2, "0")
end
