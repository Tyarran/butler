defmodule Butler.Jobs.JobTest do
  use ExUnit.Case, async: true

  alias Butler.Jobs.Job

  @now ~U[2026-01-01 12:00:00Z]

  defp row(overrides \\ %{}) do
    Map.merge(
      %{
        "id" => "j1",
        "kind" => "mine",
        "payload_json" => ~s({"source":"/tmp/x","dry_run":true}),
        "state" => "succeeded",
        "priority" => 3,
        "dedupe_key" => "abc",
        "created_at" => "2026-01-01T10:00:00.000000+00:00",
        "started_at" => "2026-01-01T10:01:00+00:00",
        "finished_at" => "2026-01-01T10:06:30+00:00",
        "result_json" => ~s({"success":true,"stdout":"Done."}),
        "error_json" => nil,
        "attempts" => 1
      },
      overrides
    )
  end

  describe "from_row/1" do
    test "parses a complete row" do
      job = Job.from_row(row())

      assert %Job{
               id: "j1",
               kind: "mine",
               state: :succeeded,
               priority: 3,
               dedupe_key: "abc",
               attempts: 1,
               payload: %{"source" => "/tmp/x", "dry_run" => true},
               result: %{"success" => true, "stdout" => "Done."},
               error: nil
             } = job

      assert job.created_at == ~U[2026-01-01 10:00:00.000000Z]
      assert job.started_at == ~U[2026-01-01 10:01:00Z]
      assert job.finished_at == ~U[2026-01-01 10:06:30Z]
    end

    test "maps every known state to an atom" do
      for {string, atom} <- [
            {"queued", :queued},
            {"running", :running},
            {"succeeded", :succeeded},
            {"failed", :failed},
            {"cancelled", :cancelled}
          ] do
        assert Job.from_row(row(%{"state" => string})).state == atom
      end
    end

    test "unknown states become :unknown without creating atoms" do
      weird = "never_seen_state_#{System.unique_integer([:positive])}"
      assert Job.from_row(row(%{"state" => weird})).state == :unknown

      assert_raise ArgumentError, fn -> String.to_existing_atom(weird) end
    end

    test "tolerates malformed JSON by keeping the raw string" do
      job = Job.from_row(row(%{"payload_json" => "{not json", "error_json" => "oops"}))

      assert job.payload == "{not json"
      assert job.error == "oops"
    end

    test "tolerates null and empty JSON columns" do
      job = Job.from_row(row(%{"payload_json" => nil, "result_json" => ""}))

      assert job.payload == nil
      assert job.result == nil
    end

    test "tolerates invalid and missing timestamps" do
      job =
        Job.from_row(row(%{"created_at" => "garbage", "started_at" => nil, "finished_at" => ""}))

      assert job.created_at == nil
      assert job.started_at == nil
      assert job.finished_at == nil
    end

    test "defaults priority and attempts when null" do
      job = Job.from_row(row(%{"priority" => nil, "attempts" => nil}))

      assert job.priority == 0
      assert job.attempts == 0
    end
  end

  describe "active?/1" do
    test "is true for queued and running jobs only" do
      assert Job.active?(%Job{state: :queued})
      assert Job.active?(%Job{state: :running})
      refute Job.active?(%Job{state: :succeeded})
      refute Job.active?(%Job{state: :failed})
      refute Job.active?(%Job{state: :unknown})
    end
  end

  describe "duration/2" do
    test "is the elapsed time so far for a running job" do
      job = %Job{state: :running, started_at: ~U[2026-01-01 11:58:00Z]}
      assert Job.duration(job, @now) == 120
    end

    test "is finished_at - started_at for a finished job" do
      job = %Job{
        state: :succeeded,
        started_at: ~U[2026-01-01 10:00:00Z],
        finished_at: ~U[2026-01-01 10:05:30Z]
      }

      assert Job.duration(job, @now) == 330
    end

    test "is nil for a queued job or when timestamps are missing" do
      assert Job.duration(%Job{state: :queued}, @now) == nil
      assert Job.duration(%Job{state: :failed, started_at: nil, finished_at: nil}, @now) == nil

      assert Job.duration(%Job{state: :succeeded, started_at: @now, finished_at: nil}, @now) ==
               nil
    end

    test "is never negative" do
      job = %Job{state: :running, started_at: ~U[2026-01-01 12:00:10Z]}
      assert Job.duration(job, @now) == 0
    end
  end
end
