defmodule Butler.Jobs.QueueTest do
  use ExUnit.Case, async: true

  alias Butler.Jobs.Job
  alias Butler.Jobs.Queue
  alias Butler.Jobs.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    path = Path.join([tmp, "state", "queue.sqlite3"])
    name = :"queue_#{System.unique_integer([:positive])}"
    start_supervised!({Queue, name: name, path: path})
    Queue.subscribe()
    {:ok, q: name, path: path}
  end

  test "enqueue creates, broadcasts and dedupes", %{q: q} do
    assert {:ok, %Job{id: id, state: :queued}, :created} =
             Queue.enqueue(q, %{kind: "mine", dedupe_key: "k"})

    assert_receive {:job_changed, %Job{id: ^id, state: :queued}}

    assert {:ok, %Job{id: ^id}, :deduplicated} =
             Queue.enqueue(q, %{kind: "mine", dedupe_key: "k"})

    refute_receive {:job_changed, _}, 50
  end

  test "dedupe holds across connections (unique index)", %{q: q, path: path} do
    {:ok, other} = Store.open(path)
    on_exit(fn -> Store.close(other) end)

    assert {:ok, %Job{id: id}, :created} = Store.enqueue(other, %{kind: "sweep", dedupe_key: "d"})

    assert {:ok, %Job{id: ^id}, :deduplicated} =
             Queue.enqueue(q, %{kind: "sweep", dedupe_key: "d"})
  end

  test "claims are serialized: each job is claimed once, in order", %{q: q} do
    {:ok, a, _} = Queue.enqueue(q, %{kind: "mine"}, now: ~U[2026-01-01 10:00:00Z])
    {:ok, b, _} = Queue.enqueue(q, %{kind: "mine"}, now: ~U[2026-01-01 10:00:01Z])

    claimed =
      1..3
      |> Task.async_stream(fn _ -> Queue.claim_next(q) end)
      |> Enum.map(fn {:ok, {:ok, job}} -> job && job.id end)

    assert Enum.sort(Enum.reject(claimed, &is_nil/1)) == Enum.sort([a.id, b.id])
    assert Enum.count(claimed, &is_nil/1) == 1
  end

  test "claim, finish and defer broadcast", %{q: q} do
    {:ok, job, _} = Queue.enqueue(q, %{kind: "mine"})
    id = job.id
    assert_receive {:job_changed, %Job{id: ^id, state: :queued}}

    {:ok, %Job{state: :running, started_at: started}} = Queue.claim_next(q)
    assert_receive {:job_changed, %Job{id: ^id, state: :running}}

    assert {:ok, %Job{state: :queued}} = Queue.defer(q, id, started, %{message: "busy"})
    assert_receive {:job_changed, %Job{id: ^id, state: :queued}}

    {:ok, _} = Queue.claim_next(q)
    assert_receive {:job_changed, %Job{state: :running}}
    assert {:ok, %Job{state: :succeeded}} = Queue.finish(q, id, :succeeded, %{result: %{}})
    assert_receive {:job_changed, %Job{id: ^id, state: :succeeded}}
    assert {:error, :not_running} = Queue.finish(q, id, :failed)
  end

  test "cancel a queued job broadcasts; a running job stays running", %{q: q} do
    {:ok, a, _} = Queue.enqueue(q, %{kind: "mine"})
    assert_receive {:job_changed, _}
    assert {:ok, %Job{state: :cancelled}} = Queue.cancel(q, a.id)
    assert_receive {:job_changed, %Job{state: :cancelled}}

    {:ok, b, _} = Queue.enqueue(q, %{kind: "mine"})
    assert_receive {:job_changed, _}
    {:ok, _} = Queue.claim_next(q)
    assert_receive {:job_changed, %Job{state: :running}}
    assert {:ok, %Job{state: :running}} = Queue.cancel(q, b.id)
    refute_receive {:job_changed, _}, 50
    assert {:error, :job_not_found} = Queue.cancel(q, "missing")
  end

  test "read, recover and prune operations", %{q: q} do
    {:ok, job, _} = Queue.enqueue(q, %{kind: "mine"})
    assert {:ok, %Job{}} = Queue.get(q, job.id)
    assert {:ok, [%Job{}]} = Queue.list(q)
    assert {:ok, %{queued: 1}} = Queue.counts(q)
    assert {:ok, ["mine"]} = Queue.kinds(q)
    {:ok, _} = Queue.claim_next(q)
    assert {:ok, %{requeued: 1, failed: 0}} = Queue.recover_running(q, ["mine"])
    assert {:ok, 0} = Queue.prune_terminal(q, 7)
  end

  test "reports queue_unavailable when the server is down" do
    assert {:error, {:queue_unavailable, _}} = Queue.get(:no_such_queue, "x")
  end

  test "Jobs.Supervisor starts the queue", %{tmp_dir: tmp} do
    name = :"sup_#{System.unique_integer([:positive])}"
    path = Path.join([tmp, "sup", "queue.sqlite3"])
    start_supervised!({Butler.Jobs.Supervisor, name: name, path: path})
    assert Process.whereis(Queue)
    assert {:ok, []} = Queue.list(Queue)
  end
end
