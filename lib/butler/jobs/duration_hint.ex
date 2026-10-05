defmodule Butler.Jobs.DurationHint do
  @moduledoc """
  Tells how long a running job usually takes, based on the history of
  succeeded jobs of the same kind.

  The typical duration is the median, and is only reported when there are at
  least `min_samples/0` samples.
  """

  alias Butler.Jobs.Job

  @min_samples 3
  @seconds_per_minute 60

  @doc "Minimum number of succeeded jobs needed to compute a typical duration."
  @spec min_samples() :: pos_integer()
  def min_samples, do: @min_samples

  @doc """
  Median duration in seconds of the succeeded jobs of `kind` in `history`,
  or `nil` when there are fewer than `min_samples/0` of them.
  """
  @spec typical_seconds([Job.t()], String.t() | nil) :: non_neg_integer() | nil
  def typical_seconds(history, kind) do
    durations =
      history
      |> Enum.filter(&(&1.state == :succeeded and &1.kind == kind))
      |> Enum.map(&Job.duration/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.sort()

    if length(durations) >= @min_samples, do: median(durations)
  end

  @doc """
  A human hint for a running job, e.g.
  `"running for 2 min, usual duration ~5 min"`, or `nil` when the job is not
  running or there is not enough history.
  """
  @spec hint(Job.t(), [Job.t()], DateTime.t()) :: String.t() | nil
  def hint(job, history, now \\ DateTime.utc_now())

  def hint(%Job{state: :running} = job, history, now) do
    with typical when is_integer(typical) <- typical_seconds(history, job.kind),
         elapsed when is_integer(elapsed) <- Job.duration(job, now) do
      "running for #{minutes(elapsed)} min, usual duration ~#{minutes(typical)} min"
    end
  end

  def hint(%Job{}, _history, _now), do: nil

  defp median(sorted) do
    count = length(sorted)
    middle = div(count, 2)

    if rem(count, 2) == 1 do
      Enum.at(sorted, middle)
    else
      div(Enum.at(sorted, middle - 1) + Enum.at(sorted, middle), 2)
    end
  end

  defp minutes(seconds), do: max(round(seconds / @seconds_per_minute), 1)
end
