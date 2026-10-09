defmodule Butler.Jobs.StoreRWTest do
  use ExUnit.Case, async: true

  alias Butler.Jobs.Job
  alias Butler.Jobs.Store
  alias Exqlite.Sqlite3

  @t0 ~U[2026-01-01 10:00:00.000Z]
  @idempotent ~w(mine sweep sync)

  setup %{tmp_dir: tmp} do
    path = Path.join([tmp, "state", "queue.sqlite3"])
    {:ok, db} = Store.open(path)
    on_exit(fn -> Store.close(db) end)
    {:ok, db: db, path: path}
  end

  defp at(seconds), do: [now: DateTime.add(@t0, seconds)]

  defp enqueue!(db, kind, extra \\ %{}, seconds \\ 0) do
    {:ok, job, :created} = Store.enqueue(db, Map.merge(%{kind: kind}, extra), at(seconds))
    job
  end

  defp claim!(db, exclude \\ [], seconds \\ 100) do
    {:ok, %Job{} = job} = Store.claim_next(db, exclude, at(seconds))
    job
  end

  defp mode(path), do: Bitwise.band(File.stat!(path).mode, 0o777)

  describe "open/1" do
    @tag :tmp_dir
    test "creates the dir (700) and the database files (600)", %{path: path} do
      assert mode(Path.dirname(path)) == 0o700
      assert mode(path) == 0o600
      assert mode(path <> "-wal") == 0o600
      assert mode(path <> "-shm") == 0o600
    end

    @tag :tmp_dir
    test "creates the schema in WAL mode with user_version 1", %{db: db} do
      assert {:ok, _, [["wal"]]} = pragma(db, "journal_mode")
      assert {:ok, _, [[1]]} = pragma(db, "user_version")

      {:ok, _, rows} = query(db, "SELECT name FROM pragma_table_info('jobs')")

      assert List.flatten(rows) ==
               ~w(id kind payload_json state priority dedupe_key created_at started_at
                  finished_at result_json error_json attempts os_pid)

      {:ok, _, rows} = query(db, "SELECT name FROM sqlite_master WHERE type = 'index'")
      names = List.flatten(rows)
      assert "idx_jobs_state" in names
      assert "idx_jobs_dedupe_active" in names
    end

    @tag :tmp_dir
    test "is idempotent and keeps existing jobs", %{db: db, path: path} do
      job = enqueue!(db, "mine")
      Store.close(db)

      {:ok, db2} = Store.open(path)
      on_exit(fn -> Store.close(db2) end)
      assert {:ok, %Job{id: id}} = Store.get(db2, job.id)
      assert id == job.id
    end

    @tag :tmp_dir
    test "refuses a database with a newer user_version", %{tmp_dir: tmp} do
      path = Path.join(tmp, "future.sqlite3")
      {:ok, raw} = Sqlite3.open(path)
      :ok = Sqlite3.execute(raw, "PRAGMA user_version = 99")
      Sqlite3.close(raw)

      assert Store.open(path) == {:error, {:unsupported_user_version, 99}}
    end

    @tag :tmp_dir
    test "rejects an unknown state through the CHECK constraint", %{db: db} do
      assert {:error, _reason} =
               Sqlite3.execute(
                 db,
                 "INSERT INTO jobs (id, kind, payload_json, state, created_at) " <>
                   "VALUES ('x', 'mine', '{}', 'bogus', 't')"
               )
    end
  end

  describe "enqueue/3" do
    @tag :tmp_dir
    test "inserts a queued job with a JSON payload", %{db: db} do
      {:ok, job, :created} =
        Store.enqueue(
          db,
          %{kind: "mine", payload: %{"source" => "/tmp/x"}, priority: 5, dedupe_key: "k"},
          at(0)
        )

      assert %Job{
               kind: "mine",
               state: :queued,
               priority: 5,
               dedupe_key: "k",
               attempts: 0,
               payload: %{"source" => "/tmp/x"}
             } = job

      assert job.created_at == @t0
    end

    @tag :tmp_dir
    test "deduplicates against a queued or running job", %{db: db} do
      first = enqueue!(db, "mine", %{dedupe_key: "same"})

      assert {:ok, %Job{id: id}, :deduplicated} =
               Store.enqueue(db, %{kind: "mine", dedupe_key: "same"})

      assert id == first.id

      claim!(db)

      assert {:ok, %Job{id: ^id}, :deduplicated} =
               Store.enqueue(db, %{kind: "mine", dedupe_key: "same"})

      assert {:ok, %{queued: 0, running: 1}} = Store.counts(db)
    end

    @tag :tmp_dir
    test "a terminal job no longer blocks its dedupe_key", %{db: db} do
      first = enqueue!(db, "mine", %{dedupe_key: "same"})
      claim!(db)
      {:ok, _} = Store.finish(db, first.id, :succeeded)

      assert {:ok, second, :created} = Store.enqueue(db, %{kind: "mine", dedupe_key: "same"})
      refute second.id == first.id
    end

    @tag :tmp_dir
    test "jobs without dedupe_key never collide", %{db: db} do
      enqueue!(db, "mine")
      enqueue!(db, "mine")
      assert {:ok, %{queued: 2}} = Store.counts(db)
    end
  end

  describe "claim_next/3" do
    @tag :tmp_dir
    test "claims by priority DESC, created_at ASC, then insertion order", %{db: db} do
      low = enqueue!(db, "mine", %{priority: 0}, 0)
      tie_a = enqueue!(db, "sweep", %{priority: 5}, 10)
      tie_b = enqueue!(db, "sweep", %{priority: 5}, 10)
      early_high = enqueue!(db, "sync", %{priority: 5}, 5)

      order = for _ <- 1..4, do: claim!(db).id

      assert order == [early_high.id, tie_a.id, tie_b.id, low.id]
      assert {:ok, nil} = Store.claim_next(db)
    end

    @tag :tmp_dir
    test "marks running, increments attempts, clears error and os_pid", %{db: db} do
      job = enqueue!(db, "mine")
      claimed = claim!(db)

      assert %Job{state: :running, attempts: 1, os_pid: nil, error: nil} = claimed
      assert claimed.id == job.id
      assert claimed.started_at == DateTime.add(@t0, 100)
    end

    @tag :tmp_dir
    test "skips excluded ids", %{db: db} do
      a = enqueue!(db, "mine", %{}, 0)
      b = enqueue!(db, "mine", %{}, 1)

      assert claim!(db, [a.id]).id == b.id
      assert {:ok, nil} = Store.claim_next(db, [a.id])
    end
  end

  describe "set_os_pid/3, finish/5" do
    @tag :tmp_dir
    test "records the pid of a running job only", %{db: db} do
      job = enqueue!(db, "mine")
      assert {:error, :not_running} = Store.set_os_pid(db, job.id, 42)

      claim!(db)
      assert {:ok, %Job{os_pid: 42}} = Store.set_os_pid(db, job.id, 42)
    end

    @tag :tmp_dir
    test "finish stores result/error, clears os_pid and is guarded", %{db: db} do
      job = enqueue!(db, "mine")
      claim!(db)
      {:ok, _} = Store.set_os_pid(db, job.id, 42)

      assert {:ok, %Job{state: :succeeded, os_pid: nil, result: %{"exit" => 0}} = done} =
               Store.finish(db, job.id, :succeeded, %{result: %{exit: 0}}, at(200))

      assert done.finished_at == DateTime.add(@t0, 200)
      assert {:error, :not_running} = Store.finish(db, job.id, :failed)
      assert {:ok, %Job{state: :succeeded}} = Store.get(db, job.id)
    end

    @tag :tmp_dir
    test "finish can record a failure", %{db: db} do
      job = enqueue!(db, "mine")
      claim!(db)

      assert {:ok, %Job{state: :failed, error: %{"class" => "Boom"}}} =
               Store.finish(db, job.id, :failed, %{error: %{class: "Boom"}})
    end
  end

  describe "defer/4" do
    @tag :tmp_dir
    test "requeues, refunds the attempt and records the error", %{db: db} do
      job = enqueue!(db, "mine")
      claimed = claim!(db)
      {:ok, _} = Store.set_os_pid(db, job.id, 42)

      assert {:ok, %Job{state: :queued, attempts: 0, started_at: nil, os_pid: nil} = deferred} =
               Store.defer(db, job.id, claimed.started_at, %{class: "LockHeldByOtherProcess"})

      assert deferred.error == %{"class" => "LockHeldByOtherProcess"}
      assert claim!(db, [], 300).attempts == 1
    end

    @tag :tmp_dir
    test "is guarded on the claim's started_at", %{db: db} do
      job = enqueue!(db, "mine")
      claimed = claim!(db)

      assert {:error, :not_running} =
               Store.defer(db, job.id, DateTime.add(claimed.started_at, -1), %{})

      assert {:ok, %Job{state: :running}} = Store.get(db, job.id)
    end

    @tag :tmp_dir
    test "does nothing on a job that is not running", %{db: db} do
      job = enqueue!(db, "mine")
      assert {:error, :not_running} = Store.defer(db, job.id, @t0, %{})
    end
  end

  describe "cancel/3" do
    @tag :tmp_dir
    test "cancels a queued job directly", %{db: db} do
      job = enqueue!(db, "mine")

      assert {:ok, %Job{state: :cancelled, finished_at: %DateTime{}}} =
               Store.cancel(db, job.id, at(5))

      assert {:ok, nil} = Store.claim_next(db)
    end

    @tag :tmp_dir
    test "leaves a running job to the worker", %{db: db} do
      job = enqueue!(db, "mine")
      claim!(db)

      assert {:ok, %Job{state: :running}} = Store.cancel(db, job.id)
    end

    @tag :tmp_dir
    test "refuses terminal and unknown jobs", %{db: db} do
      job = enqueue!(db, "mine")
      claim!(db)
      {:ok, _} = Store.finish(db, job.id, :succeeded)

      assert {:error, :not_cancellable} = Store.cancel(db, job.id)
      assert {:error, :job_not_found} = Store.cancel(db, "missing")
    end
  end

  describe "recover_running/3" do
    defp running!(db, kind, attempts) do
      job = enqueue!(db, kind)
      for _ <- 1..attempts, do: force_attempt(db, job.id)
      {:ok, _} = Store.set_os_pid(db, job.id, 7)
      job.id
    end

    # claim, then re-queue manually until `attempts` reaches the wanted value
    defp force_attempt(db, id) do
      case Store.get(db, id) do
        {:ok, %Job{state: :queued}} -> {:ok, %Job{}} = Store.claim_next(db, [])
        {:ok, %Job{state: :running}} -> :ok = Sqlite3.execute(db, bump(id))
      end
    end

    defp bump(id), do: "UPDATE jobs SET attempts = attempts + 1 WHERE id = '#{id}'"

    @tag :tmp_dir
    test "requeues idempotent jobs under the attempt limit", %{db: db} do
      id = running!(db, "mine", 2)

      assert {:ok, %{requeued: 1, failed: 0}} =
               Store.recover_running(db, @idempotent, now: @t0)

      assert {:ok, %Job{state: :queued, started_at: nil, os_pid: nil, attempts: 2}} =
               Store.get(db, id)
    end

    @tag :tmp_dir
    test "fails idempotent jobs that reached max attempts", %{db: db} do
      id = running!(db, "sweep", 3)

      assert {:ok, %{requeued: 0, failed: 1}} = Store.recover_running(db, @idempotent, at(1))

      assert {:ok, %Job{state: :failed, error: %{"class" => "MaxAttemptsExceeded"}}} =
               Store.get(db, id)
    end

    @tag :tmp_dir
    test "fails non-idempotent kinds whatever the attempts", %{db: db} do
      ids =
        for kind <- ~w(diary_write mcp_tool repair compress migrate-wings),
            do: running!(db, kind, 1)

      assert {:ok, %{requeued: 0, failed: 5}} = Store.recover_running(db, @idempotent)

      for id <- ids do
        assert {:ok, %Job{state: :failed, error: %{"class" => "Interrupted"}}} = Store.get(db, id)
      end
    end

    @tag :tmp_dir
    test "leaves queued and terminal jobs alone", %{db: db} do
      queued = enqueue!(db, "mine")

      assert {:ok, %{requeued: 0, failed: 0}} = Store.recover_running(db, @idempotent)
      assert {:ok, %Job{state: :queued}} = Store.get(db, queued.id)
    end
  end

  describe "prune_terminal/3" do
    @tag :tmp_dir
    test "deletes terminal jobs older than the retention only", %{db: db} do
      old_ok = enqueue!(db, "mine")
      old_failed = enqueue!(db, "mine")
      recent = enqueue!(db, "mine")
      queued = enqueue!(db, "mine")

      for {job, state, seconds} <- [
            {old_ok, :succeeded, 0},
            {old_failed, :failed, 0},
            {recent, :succeeded, 6 * 86_400}
          ] do
        claim!(db, [queued.id])
        {:ok, _} = Store.finish(db, job.id, state, %{}, at(seconds))
      end

      assert {:ok, 2} = Store.prune_terminal(db, 7, now: DateTime.add(@t0, 8 * 86_400))
      assert {:ok, ids} = Store.list(db)
      assert Enum.sort(Enum.map(ids, & &1.id)) == Enum.sort([recent.id, queued.id])
    end
  end

  describe "reads on a handle" do
    @tag :tmp_dir
    test "counts, kinds, list and get", %{db: db} do
      a = enqueue!(db, "sweep")
      enqueue!(db, "mine")

      assert {:ok, %{queued: 2, running: 0, succeeded: 0, failed: 0, cancelled: 0}} =
               Store.counts(db)

      assert Store.kinds(db) == {:ok, ["mine", "sweep"]}
      assert {:ok, [_, _]} = Store.list(db)
      assert {:ok, [%Job{kind: "sweep"}]} = Store.list(db, kind: "sweep")
      assert {:ok, %Job{id: id}} = Store.get(db, a.id)
      assert id == a.id
      assert {:error, :job_not_found} = Store.get(db, "nope")
    end
  end

  defp pragma(db, name), do: query(db, "PRAGMA #{name}")

  defp query(db, sql) do
    {:ok, stmt} = Sqlite3.prepare(db, sql)
    {:ok, columns} = Sqlite3.columns(db, stmt)
    {:ok, rows} = Sqlite3.fetch_all(db, stmt)
    Sqlite3.release(db, stmt)
    {:ok, columns, rows}
  end
end
