defmodule Butler.Jobs.DurationHintTest do
  use ExUnit.Case, async: true

  alias Butler.Jobs.DurationHint
  alias Butler.Jobs.Job

  @now ~U[2026-01-01 12:00:00Z]

  defp done(kind, seconds, state \\ :succeeded) do
    started = ~U[2026-01-01 10:00:00Z]

    %Job{
      id: "d#{System.unique_integer([:positive])}",
      kind: kind,
      state: state,
      started_at: started,
      finished_at: DateTime.add(started, seconds, :second)
    }
  end

  defp running(kind, seconds_ago),
    do: %Job{
      id: "r",
      kind: kind,
      state: :running,
      started_at: DateTime.add(@now, -seconds_ago, :second)
    }

  describe "typical_seconds/2" do
    test "is the median of succeeded jobs of the same kind" do
      history = [done("mine", 60), done("mine", 600), done("mine", 300), done("mcp_tool", 5)]
      assert DurationHint.typical_seconds(history, "mine") == 300
    end

    test "averages the two middle values for an even count" do
      history = [done("mine", 100), done("mine", 200), done("mine", 300), done("mine", 400)]
      assert DurationHint.typical_seconds(history, "mine") == 250
    end

    test "ignores failed jobs" do
      history = [done("mine", 60), done("mine", 60), done("mine", 9000, :failed)]
      assert DurationHint.typical_seconds(history, "mine") == nil
    end

    test "is nil below the minimum number of samples" do
      assert DurationHint.min_samples() >= 2
      history = for _ <- 1..(DurationHint.min_samples() - 1), do: done("mine", 60)
      assert DurationHint.typical_seconds(history, "mine") == nil
    end

    test "is available at the minimum number of samples" do
      history = for _ <- 1..DurationHint.min_samples(), do: done("mine", 60)
      assert DurationHint.typical_seconds(history, "mine") == 60
    end
  end

  describe "hint/3" do
    setup do
      {:ok, history: for(s <- [240, 300, 360], do: done("mine", s))}
    end

    test "describes a running job against the usual duration", %{history: history} do
      assert DurationHint.hint(running("mine", 120), history, @now) ==
               "running for 2 min, usual duration ~5 min"
    end

    test "is nil when there is not enough history" do
      assert DurationHint.hint(running("mine", 120), [], @now) == nil
    end

    test "is nil for kinds without history", %{history: history} do
      assert DurationHint.hint(running("mcp_tool", 120), history, @now) == nil
    end

    test "is nil for jobs that are not running", %{history: history} do
      assert DurationHint.hint(%Job{id: "q", kind: "mine", state: :queued}, history, @now) == nil
      assert DurationHint.hint(done("mine", 100), history, @now) == nil
    end
  end
end
