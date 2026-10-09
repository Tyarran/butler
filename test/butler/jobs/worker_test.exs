defmodule Butler.Jobs.WorkerTest do
  # Global Mox mode: the CLI is called from tasks spawned by the worker.
  use ExUnit.Case, async: false

  import Mox

  alias Butler.Jobs.Job
  alias Butler.Jobs.Kinds
  alias Butler.Jobs.Queue
  alias Butler.Jobs.Worker
  alias Butler.Maintenance
  alias Butler.MCP
  alias Butler.MCP.Writer

  @moduletag :tmp_dir

  @palace "/tmp/synthetic/palace"

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{tmp_dir: tmp} do
    q = :"queue_#{System.unique_integer([:positive])}"
    path = Path.join(tmp, "queue.sqlite3")
    start_supervised!({Queue, name: q, path: path})
    Queue.subscribe()
    {:ok, q: q, tmp: tmp}
  end

  defp start_worker(q, opts \\ []) do
    name = :"worker_#{System.unique_integer([:positive])}"

    opts =
      Keyword.merge(
        [name: name, queue: q, palace: @palace, grace_ms: 50, legacy_running?: fn -> false end],
        opts
      )

    start_supervised!({Worker, opts})
    # Boot runs in handle_continue: this call returns once it is over.
    _ = Worker.status(name)
    name
  end

  defp enqueue(q, kind, payload, opts \\ []) do
    {:ok, job, :created} = Queue.enqueue(q, %{kind: kind, payload: payload}, opts)
    job
  end

  defp mine(q, name, opts \\ []) do
    {attrs_opts, enqueue_opts} = Keyword.split(opts, [:priority])
    payload = %{"source" => "/tmp/synthetic/#{name}"}

    {:ok, job, :created} =
      Queue.enqueue(
        q,
        Map.merge(%{kind: "mine", payload: payload}, Map.new(attrs_opts)),
        enqueue_opts
      )

    job
  end

  # A CLI call that reports itself to the test and waits to be told how to end.
  defp blocking_cli(test) do
    fn argv, opts ->
      if on_start = opts[:on_start], do: on_start.(4242)
      send(test, {:run, self(), argv, opts})

      receive do
        {:finish, result} -> result
      end
    end
  end

  defp finish(runner, result), do: send(runner, {:finish, result})
  defp ok_result, do: {:ok, %{status: 0, output: "ok\n"}}

  defp await_state(id, state, timeout \\ 2_000) do
    assert_receive {:job_changed, %Job{id: ^id, state: ^state} = job}, timeout
    job
  end

  describe "serial execution" do
    test "runs one job at a time in claim order (priority first)", %{q: q} do
      low = mine(q, "low")
      high = mine(q, "high", priority: 5)

      stub(Butler.CLIMock, :run, blocking_cli(self()))
      start_worker(q)

      assert_receive {:run, first, argv1, opts}
      assert "/tmp/synthetic/high" in argv1
      assert "--direct" in argv1
      refute "--daemon" in argv1
      assert opts[:env] == Kinds.routing_env()
      assert opts[:timeout] == Kinds.timeout_ms("mine")

      # The second job waits while the first one runs.
      refute_receive {:run, _, _, _}, 100
      finish(first, ok_result())
      await_state(high.id, :succeeded)

      assert_receive {:run, second, argv2, _}
      assert "/tmp/synthetic/low" in argv2
      finish(second, ok_result())
      done = await_state(low.id, :succeeded)

      assert done.result["exit_status"] == 0
      assert done.result["output_tail"] == "ok\n"
    end

    test "wakes on enqueue and reports its status", %{q: q} do
      Worker.subscribe()
      stub(Butler.CLIMock, :run, blocking_cli(self()))
      worker = start_worker(q)
      assert_receive {:worker_changed, :idle}
      assert %{status: :idle, active_job_id: nil} = Worker.status(worker)

      job = mine(q, "a")
      assert_receive {:run, runner, _argv, _opts}
      assert_receive {:worker_changed, :running}
      assert %{status: :running, active_job_id: id} = Worker.status(worker)
      assert id == job.id

      finish(runner, ok_result())
      assert_receive {:worker_changed, :idle}
    end

    test "an on_start with a nil os_pid (instant exit) does not crash the queue", %{q: q} do
      queue_pid = Process.whereis(q)

      stub(Butler.CLIMock, :run, fn _argv, opts ->
        opts[:on_start].(nil)
        ok_result()
      end)

      job = mine(q, "instant")
      start_worker(q)

      await_state(job.id, :succeeded)
      assert Process.whereis(q) == queue_pid
    end

    test "broadcasts output lines on the job topic", %{q: q} do
      Phoenix.PubSub.subscribe(Butler.PubSub, "butler:job:job-out")

      stub(Butler.CLIMock, :run, fn _argv, opts ->
        opts[:on_output].("hello")
        ok_result()
      end)

      {:ok, _job, :created} =
        Queue.enqueue(q, %{kind: "sweep", payload: %{"target" => "/tmp/t"}}, id: "job-out")

      start_worker(q)
      assert_receive {:job_output, "job-out", "hello"}
    end
  end

  describe "failures" do
    test "a non-zero exit fails the job with the output tail and no retry", %{q: q} do
      job = mine(q, "a")
      expect(Butler.CLIMock, :run, fn _argv, _opts -> {:ok, %{status: 3, output: "boom\n"}} end)
      start_worker(q)

      failed = await_state(job.id, :failed)
      assert failed.error["class"] == "CommandFailed"
      assert failed.error["exit_status"] == 3
      assert failed.error["output_tail"] == "boom\n"
      assert failed.attempts == 1
    end

    test "a timeout fails the job; the per-kind timeout is passed to the CLI", %{q: q} do
      job = mine(q, "a")

      expect(Butler.CLIMock, :run, fn _argv, opts ->
        assert opts[:timeout] == 1_500
        {:error, {:timeout, "partial\n"}}
      end)

      start_worker(q, timeouts: %{"mine" => 1_500})
      failed = await_state(job.id, :failed)
      assert failed.error["class"] == "Timeout"
      assert failed.error["output_tail"] == "partial\n"
    end

    test "an invalid payload fails without calling the CLI", %{q: q} do
      job = enqueue(q, "mine", %{"source" => "relative"})
      start_worker(q)
      assert await_state(job.id, :failed).error["class"] == "InvalidPayload"
    end

    @tag :capture_log
    test "a crashing runner fails the job and the worker keeps going", %{q: q} do
      bad = mine(q, "bad")
      good = mine(q, "good")

      Butler.CLIMock
      |> expect(:run, fn _argv, _opts -> raise "synthetic crash" end)
      |> expect(:run, fn _argv, _opts -> ok_result() end)

      start_worker(q)
      assert await_state(bad.id, :failed).error["class"] == "RunnerCrashed"
      await_state(good.id, :succeeded)
    end
  end

  describe "lock refusal" do
    @refusal "mempalace: palace /p is held by PID 1 (x); wait for it to finish or stop the holder before retrying\n"

    test "re-queues with the attempt refunded and cools down while others run", %{q: q} do
      refused = mine(q, "refused")
      other = mine(q, "other")

      Butler.CLIMock
      |> expect(:run, fn argv, _opts ->
        assert "/tmp/synthetic/refused" in argv
        {:ok, %{status: 1, output: @refusal}}
      end)
      |> expect(:run, fn argv, _opts ->
        # The refused job is cooling down, so the next one runs first.
        assert "/tmp/synthetic/other" in argv
        ok_result()
      end)
      |> expect(:run, fn argv, _opts ->
        assert "/tmp/synthetic/refused" in argv
        ok_result()
      end)

      start_worker(q, lock_backoff_ms: 300)

      refused_id = refused.id
      assert_receive {:job_changed, %Job{id: ^refused_id, state: :queued, error: %{}} = deferred}
      assert deferred.error["class"] == "LockHeldByOtherProcess"
      assert deferred.attempts == 0

      await_state(other.id, :succeeded)

      # Claimed again once the cooldown is over.
      done = await_state(refused.id, :succeeded)
      assert done.attempts == 1
    end

    test "the backoff comes from BUTLER_LOCK_BACKOFF_SECONDS, invalid falls back to 60 s" do
      on_exit(fn -> System.delete_env("BUTLER_LOCK_BACKOFF_SECONDS") end)
      System.put_env("BUTLER_LOCK_BACKOFF_SECONDS", "7")
      assert Worker.lock_backoff_ms() == 7_000

      for invalid <- ["0", "-3", "abc", "1.5", ""] do
        System.put_env("BUTLER_LOCK_BACKOFF_SECONDS", invalid)
        assert Worker.lock_backoff_ms() == 60_000
      end

      System.delete_env("BUTLER_LOCK_BACKOFF_SECONDS")
      assert Worker.lock_backoff_ms() == 60_000
    end
  end

  describe "cancel" do
    test "a running job: TERM by os_pid, then cancelled", %{q: q} do
      job = mine(q, "a")
      parent = self()

      stub(Butler.CLIMock, :run, blocking_cli(self()))

      worker =
        start_worker(q, signal: fn pid, name -> send(parent, {:signal, pid, name}) end)

      assert_receive {:run, runner, _argv, _opts}
      _ = Worker.status(worker)
      assert {:ok, %Job{os_pid: 4242}} = Queue.get(q, job.id)

      assert {:ok, %Job{state: :running}} = Worker.cancel(worker, job.id)
      assert_receive {:signal, 4242, "TERM"}

      # The process dies of the signal.
      finish(runner, {:ok, %{status: 143, output: "terminated\n"}})
      cancelled = await_state(job.id, :cancelled)
      assert cancelled.error["class"] == "Cancelled"
      assert %{status: :idle} = Worker.status(worker)
    end

    test "escalates to KILL after the grace period", %{q: q} do
      job = mine(q, "a")
      parent = self()
      stub(Butler.CLIMock, :run, blocking_cli(self()))

      worker =
        start_worker(q, signal: fn pid, name -> send(parent, {:signal, pid, name}) end)

      assert_receive {:run, runner, _argv, _opts}
      _ = Worker.status(worker)
      {:ok, _} = Worker.cancel(worker, job.id)
      assert_receive {:signal, 4242, "TERM"}
      assert_receive {:signal, 4242, "KILL"}
      finish(runner, {:ok, %{status: 137, output: ""}})
      await_state(job.id, :cancelled)
    end

    test "a cancel that arrives before the os_pid kills as soon as it is known", %{q: q} do
      job = mine(q, "a")
      parent = self()

      stub(Butler.CLIMock, :run, fn argv, opts ->
        send(parent, {:run, self(), argv, opts})

        receive do
          :start -> opts[:on_start].(777)
        end

        receive do
          {:finish, result} -> result
        end
      end)

      worker =
        start_worker(q, signal: fn pid, name -> send(parent, {:signal, pid, name}) end)

      assert_receive {:run, runner, _argv, _opts}
      {:ok, _} = Worker.cancel(worker, job.id)
      refute_receive {:signal, _, _}, 50
      send(runner, :start)
      assert_receive {:signal, 777, "TERM"}
      finish(runner, {:ok, %{status: 143, output: ""}})
      await_state(job.id, :cancelled)
    end

    test "a queued job is cancelled directly; unknown id is an error", %{q: q} do
      stub(Butler.CLIMock, :run, blocking_cli(self()))
      worker = start_worker(q, legacy_running?: fn -> true end)
      job = mine(q, "a")

      assert {:ok, %Job{state: :cancelled}} = Worker.cancel(worker, job.id)
      assert {:error, :job_not_found} = Worker.cancel(worker, "missing")
    end
  end

  describe "boot" do
    test "stays blocked while the legacy daemon is alive, then goes idle", %{q: q} do
      Worker.subscribe()
      alive = :atomics.new(1, [])
      :atomics.put(alive, 1, 1)
      stub(Butler.CLIMock, :run, blocking_cli(self()))

      job = mine(q, "a")

      worker =
        start_worker(q,
          legacy_running?: fn -> :atomics.get(alive, 1) == 1 end,
          blocked_recheck_ms: 20
        )

      assert_receive {:worker_changed, :blocked}
      refute_receive {:run, _, _, _}, 100
      assert %{status: :blocked} = Worker.status(worker)

      :atomics.put(alive, 1, 0)
      assert_receive {:worker_changed, :idle}
      assert_receive {:run, runner, _argv, _opts}
      finish(runner, ok_result())
      await_state(job.id, :succeeded)
    end

    test "recover_running matrix before the first claim", %{q: q} do
      # Left `running` by a crash: 3 attempts (exhausted), 1 attempt, non-idempotent.
      exhausted = mine(q, "exhausted")

      for _ <- 1..2 do
        {:ok, %Job{}} = Queue.claim_next(q)
        {:ok, %{requeued: 1}} = Queue.recover_running(q, ["mine"])
      end

      {:ok, %Job{attempts: 3}} = Queue.claim_next(q)

      retry = mine(q, "retry")
      repair = enqueue(q, "repair", %{})
      {:ok, %Job{id: retry_id}} = Queue.claim_next(q)
      {:ok, %Job{id: repair_id}} = Queue.claim_next(q)
      assert {retry.id, repair.id} == {retry_id, repair_id}

      start_worker(q, legacy_running?: fn -> true end)

      assert {:ok, %Job{state: :failed, error: %{"class" => "MaxAttemptsExceeded"}}} =
               Queue.get(q, exhausted.id)

      assert {:ok, %Job{state: :queued, attempts: 1}} = Queue.get(q, retry.id)

      assert {:ok, %Job{state: :failed, error: %{"class" => "Interrupted"}}} =
               Queue.get(q, repair.id)
    end

    test "re-queues an idempotent running job and fails the others", %{q: q} do
      mined = mine(q, "mined")
      repair = enqueue(q, "repair", %{})
      {:ok, _} = Queue.claim_next(q)
      {:ok, _} = Queue.claim_next(q)

      start_worker(q, legacy_running?: fn -> true end)

      assert {:ok, %Job{state: :queued, os_pid: nil}} = Queue.get(q, mined.id)
      assert {:ok, %Job{state: :failed}} = Queue.get(q, repair.id)
    end

    test "kills an orphaned mempalace process before recovering", %{q: q, tmp: tmp} do
      job = mine(q, "orphan")
      {:ok, _} = Queue.claim_next(q)
      {:ok, _} = Queue.set_os_pid(q, job.id, 31_337)

      proc = Path.join(tmp, "proc")
      dir = Path.join(proc, "31337")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "cmdline"), "mempalace\0--palace\0/p\0mine\0/s\0--direct")
      parent = self()

      signal = fn pid, name ->
        # At signal time the job is still `running`: recovery comes after.
        {:ok, %Job{state: state}} = Queue.get(q, job.id)
        send(parent, {:signal, pid, name, state})
        File.rm_rf!(dir)
      end

      start_worker(q, legacy_running?: fn -> true end, proc_root: proc, signal: signal)

      assert_received {:signal, 31_337, "TERM", :running}
      assert {:ok, %Job{state: :queued, os_pid: nil}} = Queue.get(q, job.id)
    end
  end

  describe "graceful shutdown" do
    test "an idempotent job goes back to queued with the attempt refunded", %{q: q} do
      job = mine(q, "a")
      parent = self()
      stub(Butler.CLIMock, :run, blocking_cli(self()))

      worker =
        start_worker(q, signal: fn pid, name -> send(parent, {:signal, pid, name}) end)

      assert_receive {:run, _runner, _argv, _opts}
      _ = Worker.status(worker)
      :ok = stop_supervised(Worker)

      assert_received {:signal, 4242, "TERM"}
      assert {:ok, %Job{state: :queued, attempts: 0, error: error}} = Queue.get(q, job.id)
      assert error["message"] == "interrupted by shutdown"
    end

    test "a non-idempotent job becomes failed", %{q: q} do
      job = enqueue(q, "repair", %{})
      parent = self()
      stub(Butler.CLIMock, :run, blocking_cli(self()))

      worker =
        start_worker(q, signal: fn pid, name -> send(parent, {:signal, pid, name}) end)

      assert_receive {:run, _runner, argv, _opts}
      assert argv == ["--palace", @palace, "repair", "--yes"]
      _ = Worker.status(worker)
      :ok = stop_supervised(Worker)

      assert_received {:signal, 4242, "TERM"}

      assert {:ok, %Job{state: :failed, error: %{"message" => "interrupted by shutdown"}}} =
               Queue.get(q, job.id)
    end
  end

  test "Jobs.Supervisor restarts the worker when the queue restarts (rest_for_one)", %{tmp: tmp} do
    path = Path.join(tmp, "sup.sqlite3")
    name = :"sup_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Butler.Jobs.Supervisor, name: name, path: path, worker: [legacy_running?: fn -> false end]}
    )

    queue = Process.whereis(Queue)
    worker = Process.whereis(Worker)
    assert is_pid(queue) and is_pid(worker)

    ref = Process.monitor(worker)

    ExUnit.CaptureLog.capture_log(fn ->
      Process.exit(queue, :kill)
      assert_receive {:DOWN, ^ref, :process, ^worker, _reason}, 2_000
      # The supervisor restarts both children inside one message handler:
      # once it answers, the restart is over.
      _ = :sys.get_state(name)
      assert restarted?(queue, worker)
    end)
  end

  describe "write MCP jobs and the writer" do
    @fake_mcp Path.expand("../../support/fake_mcp.sh", __DIR__)

    defp start_writer do
      name = :"writer_#{System.unique_integer([:positive])}"

      start_supervised!({Writer, name: name, bin: @fake_mcp, startup_timeout_ms: 5_000})

      name
    end

    test "diary_write and mcp_tool run through the writer", %{q: q} do
      writer = start_writer()
      diary = enqueue(q, "diary_write", %{"agent_name" => "a", "entry" => "synthetic"})
      tool = enqueue(q, "mcp_tool", %{"name" => "mempalace_add_drawer", "arguments" => %{}})
      start_worker(q, writer: writer)

      assert %Job{result: %{"tool" => "mempalace_diary_write"}} =
               await_state(diary.id, :succeeded)

      assert %Job{result: %{"tool" => "mempalace_add_drawer"}} = await_state(tool.id, :succeeded)
      assert is_integer(Writer.os_pid(writer))
    end

    test "a failed write is failed, not retried", %{q: q} do
      writer = start_writer()
      job = enqueue(q, "mcp_tool", %{"name" => "mempalace_add_drawer", "arguments" => 1})
      start_worker(q, writer: writer)

      failed = await_state(job.id, :failed)
      assert failed.error["class"] == "InvalidPayload"
      assert Writer.os_pid(writer) == nil
    end

    test "a writer that cannot be stopped defers the CLI job without starting it", %{q: q} do
      silent = spawn_link(fn -> Process.sleep(:infinity) end)
      job = mine(q, "blocked-by-writer")
      start_worker(q, writer: silent, writer_stop_timeout_ms: 50)

      await_state(job.id, :running)
      id = job.id
      assert_receive {:job_changed, %Job{id: ^id, state: :queued, error: %{} = error} = deferred}
      assert deferred.attempts == 0
      assert inspect(error) =~ "stop_timeout"
    end

    test "the writer is stopped before every CLI job", %{q: q} do
      writer = start_writer()
      diary = enqueue(q, "diary_write", %{"agent_name" => "a", "entry" => "synthetic"})
      start_worker(q, writer: writer)
      await_state(diary.id, :succeeded)
      old = Writer.os_pid(writer)
      assert is_integer(old)

      test = self()

      stub(Butler.CLIMock, :run, fn _argv, _opts ->
        send(
          test,
          {:writer_during_cli, Writer.os_pid(writer), File.exists?("/proc/#{old}")}
        )

        ok_result()
      end)

      job = mine(q, "after-write")
      await_state(job.id, :succeeded)
      assert_received {:writer_during_cli, nil, false}
    end
  end

  describe "maintenance mode" do
    @fake_proxy Path.expand("../../support/fake_mcp.sh", __DIR__)

    setup do
      previous = Application.fetch_env(:butler, :mcp)

      Application.put_env(:butler, :mcp,
        idle_rotation_ms: 60_000,
        startup_timeout_ms: 5_000,
        backends: %{full: [bin: @fake_proxy], light: [bin: @fake_proxy]}
      )

      start_supervised!(Butler.MCP.Supervisor)
      MCP.subscribe()
      Maintenance.subscribe()

      on_exit(fn ->
        Maintenance.leave()

        case previous do
          {:ok, value} -> Application.put_env(:butler, :mcp, value)
          :error -> Application.delete_env(:butler, :mcp)
        end
      end)

      await_proxy_ready()
      :ok
    end

    defp await_proxy_ready do
      if Enum.all?(MCP.status(), &(&1.status == :ready)) and MCP.status() != [] do
        :ok
      else
        receive do
          {:mcp_changed, _backend} -> await_proxy_ready()
        after
          5_000 -> flunk("proxy never ready: #{inspect(MCP.status())}")
        end
      end
    end

    defp ping, do: %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}

    defp proxy_session do
      {:json, _result, session} =
        MCP.handle(:light, nil, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"})

      session
    end

    defp proxy_os_pids do
      for %{active: active, standby: standby} <- MCP.status(),
          view <- [active, standby],
          view,
          do: view.os_pid
    end

    defp assert_proxy_resumed(session) do
      refute Maintenance.active?()
      assert_receive {:maintenance_changed, :inactive}
      await_proxy_ready()
      assert {:json, %{"result" => %{"method" => "ping"}}} = MCP.handle(:light, session, ping())
    end

    for kind <- ~w(repair compress migrate-wings) do
      test "#{kind} gates the proxy and stops its workers for the whole run", %{q: q} do
        session = proxy_session()
        os_pids = proxy_os_pids()
        assert os_pids != []

        stub(Butler.CLIMock, :run, blocking_cli(self()))
        job = enqueue(q, unquote(kind), %{})
        start_worker(q)

        assert_receive {:run, runner, _argv, _opts}, 5_000
        assert Maintenance.active?()
        assert_received {:maintenance_changed, :active}

        # no live MCP worker, no request gets through
        assert Enum.all?(MCP.status(), &(&1.status == :suspended))
        assert Enum.all?(os_pids, &(not File.exists?("/proc/#{&1}")))

        assert {:json, %{"error" => %{"code" => -32_001}}} =
                 MCP.handle(:light, session, ping())

        finish(runner, ok_result())
        await_state(job.id, :succeeded)
        assert_proxy_resumed(session)
      end
    end

    test "a dry-run maintenance job gates too", %{q: q} do
      stub(Butler.CLIMock, :run, blocking_cli(self()))
      enqueue(q, "compress", %{"dry_run" => true})
      start_worker(q)

      assert_receive {:run, runner, argv, _opts}, 5_000
      assert "--dry-run" in argv
      assert Maintenance.active?()
      finish(runner, ok_result())
      assert_receive {:maintenance_changed, :inactive}
    end

    test "mine and sweep leave the proxy open", %{q: q} do
      session = proxy_session()
      stub(Butler.CLIMock, :run, blocking_cli(self()))
      mine(q, "reads-allowed")
      start_worker(q)

      assert_receive {:run, runner, _argv, _opts}, 5_000
      refute Maintenance.active?()
      assert Enum.all?(MCP.status(), &(&1.status == :ready))

      assert {:json, %{"result" => %{"method" => "ping"}}} = MCP.handle(:light, session, ping())

      finish(runner, ok_result())
      assert_receive {:job_changed, %Job{state: :succeeded}}
      refute_received {:maintenance_changed, _state}
    end

    test "a failing command leaves maintenance and resumes the proxy", %{q: q} do
      session = proxy_session()
      stub(Butler.CLIMock, :run, fn _argv, _opts -> {:ok, %{status: 2, output: "boom"}} end)
      job = enqueue(q, "repair", %{})
      start_worker(q)

      await_state(job.id, :failed)
      assert_proxy_resumed(session)
    end

    test "a timeout leaves maintenance and resumes the proxy", %{q: q} do
      session = proxy_session()
      stub(Butler.CLIMock, :run, fn _argv, _opts -> {:error, {:timeout, "partial"}} end)
      job = enqueue(q, "repair", %{})
      start_worker(q)

      failed = await_state(job.id, :failed)
      assert failed.error["class"] == "Timeout"
      assert_proxy_resumed(session)
    end

    @tag :capture_log
    test "a raising run leaves maintenance and resumes the proxy", %{q: q} do
      session = proxy_session()
      stub(Butler.CLIMock, :run, fn _argv, _opts -> raise "synthetic crash" end)
      job = enqueue(q, "repair", %{})
      start_worker(q)

      await_state(job.id, :failed)
      assert_proxy_resumed(session)
    end

    test "a killed run (no `after`) is cleaned up by the worker", %{q: q} do
      session = proxy_session()
      stub(Butler.CLIMock, :run, fn _argv, _opts -> Process.exit(self(), :kill) end)
      job = enqueue(q, "migrate-wings", %{})
      start_worker(q)

      await_state(job.id, :failed)
      assert_proxy_resumed(session)
    end

    test "a lock-refused maintenance job leaves maintenance too", %{q: q} do
      session = proxy_session()
      silent = spawn_link(fn -> Process.sleep(:infinity) end)
      job = enqueue(q, "repair", %{})
      start_worker(q, writer: silent, writer_stop_timeout_ms: 50)

      id = job.id
      assert_receive {:job_changed, %Job{id: ^id, state: :queued, error: %{}}}
      assert_proxy_resumed(session)
    end

    test "a stopped worker leaves maintenance", %{q: q} do
      session = proxy_session()
      stub(Butler.CLIMock, :run, blocking_cli(self()))
      enqueue(q, "repair", %{})
      start_worker(q)

      assert_receive {:run, _runner, _argv, _opts}, 5_000
      assert Maintenance.active?()

      # the real shutdown path: terminate/2 runs the cleanup
      stop_supervised!(Worker)
      assert_proxy_resumed(session)
    end

    test "the drain gives up after its timeout and the run goes on", %{q: q} do
      session = proxy_session()
      %{active: %{pid: worker}} = Enum.find(MCP.status(), &(&1.id == :light))
      hung = Task.async(fn -> MCP.handle(:light, session, %{ping() | "method" => "hang"}) end)
      await_pending(worker)

      stub(Butler.CLIMock, :run, blocking_cli(self()))
      job = enqueue(q, "repair", %{})
      start_worker(q, drain_timeout_ms: 100)

      assert_receive {:run, runner, _argv, _opts}, 5_000
      assert {:json, %{"error" => _cut}} = Task.await(hung, 5_000)
      finish(runner, ok_result())
      await_state(job.id, :succeeded)
    end

    defp await_pending(worker, tries \\ 100_000) do
      cond do
        MCP.Worker.info(worker).pending > 0 -> :ok
        tries == 0 -> flunk("request never became pending")
        true -> await_pending(worker, tries - 1)
      end
    end
  end

  defp restarted?(old_queue, old_worker) do
    queue = Process.whereis(Queue)
    worker = Process.whereis(Worker)
    is_pid(queue) and is_pid(worker) and queue != old_queue and worker != old_worker
  end
end
