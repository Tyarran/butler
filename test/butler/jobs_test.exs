defmodule Butler.JobsTest do
  use ExUnit.Case, async: false

  alias Butler.Jobs
  alias Butler.Jobs.Job
  alias Butler.Jobs.Queue
  alias Butler.Test.Engine

  @moduletag :tmp_dir

  describe "without the engine" do
    test "the worker is unavailable and cancel does not exit" do
      assert %{status: :unavailable, active_job_id: nil} = Jobs.worker_status()
      assert {:error, :worker_unavailable} = Jobs.cancel("nope")
    end

    test "queue calls report an error instead of exiting" do
      assert {:error, {:queue_unavailable, _}} = Jobs.enqueue("sweep", %{target: "/tmp"})
      assert {:error, {:queue_unavailable, _}} = Jobs.list()
    end
  end

  describe "with a queue" do
    setup %{tmp_dir: tmp} do
      Engine.start_queue!(tmp)
      :ok
    end

    test "enqueue validates the payload with the worker's rules" do
      assert {:error, {:invalid, "source", _}} = Jobs.enqueue("mine", %{source: "relative"})
      assert {:error, :unknown_kind} = Jobs.enqueue("nope", %{})
      assert {:error, {:invalid, _, _}} = Jobs.enqueue("mine", %{source: "/x", palace: "/y"})

      assert {:ok, %Job{kind: "mine", state: :queued}, :created} =
               Jobs.enqueue("mine", %{"source" => "/synthetic/project"})
    end

    test "sync defaults to a dry run" do
      assert {:ok, job, :created} = Jobs.enqueue("sync", %{})
      assert job.payload["dry_run"] == true
    end

    test "retry copies kind and payload into a new job" do
      {:ok, job, _} = Jobs.enqueue("sweep", %{"target" => "/synthetic/transcripts"})
      {:ok, _} = Queue.cancel(Queue, job.id)
      {:ok, cancelled} = Jobs.get(job.id)

      assert Jobs.retryable?(cancelled)
      assert {:ok, again, :created} = Jobs.retry(cancelled)
      assert again.id != job.id
      assert again.kind == "sweep"
      assert again.payload == cancelled.payload
    end

    test "only failed or cancelled jobs are retryable" do
      {:ok, queued, _} = Jobs.enqueue("sweep", %{"target" => "/synthetic"})
      refute Jobs.retryable?(queued)
      assert Jobs.cancellable?(queued)
      assert {:error, :not_retryable} = Jobs.retry(%Job{kind: "sweep", payload: nil})
    end

    test "positions follow the claim order (priority, then age)" do
      now = ~U[2026-01-01 10:00:00Z]
      {:ok, a, _} = Queue.enqueue(Queue, %{kind: "sweep", payload: %{target: "/a"}}, now: now)

      {:ok, b, _} =
        Queue.enqueue(Queue, %{kind: "sweep", payload: %{target: "/b"}},
          now: DateTime.add(now, 1)
        )

      {:ok, urgent, _} =
        Queue.enqueue(
          Queue,
          %{kind: "sweep", payload: %{target: "/c"}, priority: 5},
          now: DateTime.add(now, 2)
        )

      positions = Jobs.positions()
      assert positions[urgent.id] == 1
      assert positions[a.id] == 2
      assert positions[b.id] == 3
    end
  end
end
