defmodule Butler.Jobs.Worker do
  @moduledoc """
  The strictly serial worker of Butler's job queue (CLI job kinds).

  Boot: kill orphaned `mempalace` processes (`Butler.Jobs.Orphans`) ->
  `recover_running` -> prune -> legacy guard (`:blocked` while the Python
  daemon is alive) -> `:idle`. It then claims one job at a time and runs it
  in a supervised task (`Butler.Jobs.Runner.CLI`). The worker never polls:
  it wakes on `wake/1`, on `{:job_changed, %{state: :queued}}` events of the
  queue topic and at the earliest cooldown expiry.

  Outcomes of a run:

    * success -> `succeeded`; any failure, timeout or crash -> `failed` (no
      retry here, only `recover_running` re-queues);
    * palace-lock refusal -> back to `queued` with the attempt refunded, and
      the job is not claimed again for a cooldown (`BUTLER_LOCK_BACKOFF_SECONDS`,
      default #{60} s, invalid or <= 0 falls back to the default);
    * `cancel/2` of the running job -> `TERM` then `KILL` after a grace period
      (by `os_pid`), finished as `cancelled`.

  Graceful shutdown (`terminate/2`): the child is killed by `os_pid`; an
  idempotent job is put back in `queued` with its attempt refunded, any
  other job becomes `failed` ("interrupted by shutdown").

  Maintenance kinds (`repair`, `compress`, `migrate-wings`, dry-runs
  included): the worker turns `Butler.Maintenance` on when it claims the job
  (the MCP proxy then refuses every request), the run drains the proxy
  (at most 30 s), stops the writer and suspends the proxy workers, runs the
  CLI, and always leaves maintenance and resumes the proxy afterwards: in an
  `after` of the run, and again when the job is settled or the worker stops
  (crash of the run, shutdown).

  PubSub: `{:worker_changed, status}` and `{:maintenance_changed, state}` on `topic/0`;
  each output line of a job
  is broadcast as `{:job_output, id, line}` on `"butler:job:<id>"`.

  Options (mostly for tests): `:name`, `:queue` (default `Butler.Jobs.Queue`),
  `:task_supervisor`, `:timeouts` (kind => ms), `:lock_backoff_ms`,
  `:grace_ms`, `:blocked_recheck_ms`, `:palace`, `:writer` (`Butler.MCP.Writer` server), `:writer_stop_timeout_ms`, `:drain_timeout_ms` (maintenance, default 30000), `:signal` (`fn os_pid, name`,
  default `Butler.OSProcess.signal/2`), `:legacy_running?` (zero-arity fun),
  `:proc_root`.
  """

  use GenServer, shutdown: 20_000

  alias Butler.Daemon.Legacy
  alias Butler.Jobs.Job
  alias Butler.Jobs.Kinds
  alias Butler.Jobs.Orphans
  alias Butler.Jobs.Queue
  alias Butler.Jobs.Runner
  alias Butler.Maintenance
  alias Butler.MCP
  alias Butler.MCP.Writer
  alias Butler.OSProcess

  require Logger

  @topic "butler:worker"
  @default_lock_backoff_s 60
  @blocked_recheck_ms 5_000
  @retry_ms 5_000
  @mcp_kinds ~w(mcp_tool diary_write)
  @call_timeout 15_000
  @default_drain_ms 30_000

  @type status :: :booting | :blocked | :idle | :running

  @doc "Starts the worker. See the moduledoc for the options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "PubSub topic of `{:worker_changed, status}` messages."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the calling process to worker status changes."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Butler.PubSub, @topic)

  @doc "Tells an idle worker to look for a claimable job."
  @spec wake(GenServer.server()) :: :ok
  def wake(server \\ __MODULE__), do: GenServer.cast(server, :wake)

  @doc "Current status and the id of the active job, if any."
  @spec status(GenServer.server()) :: %{status: status(), active_job_id: String.t() | nil}
  def status(server \\ __MODULE__), do: GenServer.call(server, :status, @call_timeout)

  @doc """
  Cancels a job. A queued job is cancelled immediately; for the running job
  the process is stopped and the job is finished as `cancelled` shortly after
  (the returned job is still `:running`).
  """
  @spec cancel(GenServer.server(), String.t()) :: {:ok, Job.t()} | {:error, term()}
  def cancel(server \\ __MODULE__, id), do: GenServer.call(server, {:cancel, id}, @call_timeout)

  @doc "Cooldown after a lock refusal, in ms (`BUTLER_LOCK_BACKOFF_SECONDS`)."
  @spec lock_backoff_ms() :: pos_integer()
  def lock_backoff_ms do
    with value when is_binary(value) <- System.get_env("BUTLER_LOCK_BACKOFF_SECONDS"),
         {seconds, ""} when seconds > 0 <- Integer.parse(value) do
      seconds * 1_000
    else
      _ -> @default_lock_backoff_s * 1_000
    end
  end

  # -- Server ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    Queue.subscribe()

    state = %{
      queue: Keyword.get(opts, :queue, Queue),
      task_supervisor: Keyword.get(opts, :task_supervisor, Butler.TaskSupervisor),
      timeouts: Keyword.get(opts, :timeouts, %{}),
      lock_backoff_ms: Keyword.get_lazy(opts, :lock_backoff_ms, &lock_backoff_ms/0),
      grace_ms: Keyword.get(opts, :grace_ms, OSProcess.term_grace_ms()),
      recheck_ms: Keyword.get(opts, :blocked_recheck_ms, @blocked_recheck_ms),
      palace: Keyword.get(opts, :palace),
      writer: Keyword.get(opts, :writer, Writer),
      writer_stop_timeout_ms: Keyword.get(opts, :writer_stop_timeout_ms, 30_000),
      drain_ms: Keyword.get(opts, :drain_timeout_ms, @default_drain_ms),
      signal: Keyword.get(opts, :signal, &OSProcess.signal/2),
      legacy_running?: Keyword.get(opts, :legacy_running?, &Legacy.running?/0),
      proc_root: Keyword.get(opts, :proc_root, "/proc"),
      status: :booting,
      job: nil,
      task: nil,
      os_pid: nil,
      cancelling?: false,
      cooldowns: %{},
      timer: nil
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl GenServer
  def handle_continue(:boot, state) do
    # A worker killed without `terminate/2` may have left the gate closed and
    # the proxy suspended; no maintenance job runs at boot. Both are idempotent.
    Maintenance.leave()
    MCP.resume()

    with {:ok, state} <- reap_orphans(state),
         {:ok, _recovered} <- Queue.recover_running(state.queue, Kinds.idempotent_kinds()),
         {:ok, _pruned} <- Queue.prune_terminal(state.queue, Queue.retention_days()) do
      {:noreply, state |> check_legacy() |> maybe_claim()}
    else
      {:error, reason} -> {:stop, {:boot_failed, reason}, state}
    end
  end

  @impl GenServer
  def handle_call(:status, _from, state) do
    {:reply, %{status: state.status, active_job_id: active_id(state)}, state}
  end

  def handle_call({:cancel, id}, _from, %{job: %Job{id: id} = job} = state) do
    {:reply, {:ok, job}, request_cancel(state)}
  end

  def handle_call({:cancel, id}, _from, state), do: {:reply, Queue.cancel(state.queue, id), state}

  @impl GenServer
  def handle_cast(:wake, state), do: {:noreply, maybe_claim(state)}

  @impl GenServer
  def handle_info({:job_changed, %Job{state: :queued}}, state), do: {:noreply, maybe_claim(state)}
  def handle_info(:wake, state), do: {:noreply, maybe_claim(%{state | timer: nil})}

  def handle_info(:recheck_legacy, %{status: :blocked} = state),
    do: {:noreply, state |> check_legacy() |> maybe_claim()}

  # A process that already exited has no pid to record (`on_start.(nil)`).
  def handle_info({:os_pid, id, nil}, %{job: %Job{id: id}} = state), do: {:noreply, state}

  def handle_info({:os_pid, id, os_pid}, %{job: %Job{id: id}} = state) do
    _ = Queue.set_os_pid(state.queue, id, os_pid)
    state = %{state | os_pid: os_pid}
    {:noreply, if(state.cancelling?, do: terminate_child(state), else: state)}
  end

  def handle_info({:kill_grace, id}, %{job: %Job{id: id}, os_pid: os_pid} = state) do
    state.signal.(os_pid, "KILL")
    {:noreply, state}
  end

  def handle_info({:kill_pid, os_pid}, state) do
    state.signal.(os_pid, "KILL")
    {:noreply, state}
  end

  def handle_info({ref, outcome}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> settle(outcome) |> maybe_claim()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    # The port died with its owner, but the OS process may linger: TERM now,
    # KILL after the grace period (the process may outlive the job).
    state.signal.(state.os_pid, "TERM")
    schedule_kill(state)
    error = %{class: "RunnerCrashed", message: "runner crashed: #{inspect(reason)}"}
    {:noreply, state |> settle({:error, error}) |> maybe_claim()}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{job: %Job{} = job} = state) do
    state = drain_os_pid(state)
    stop_child(state)
    Task.Supervisor.terminate_child(state.task_supervisor, state.task.pid)
    leave_maintenance(job)

    interrupted = %{class: "Interrupted", message: "interrupted by shutdown"}

    if Kinds.idempotent?(job.kind) do
      Queue.defer(state.queue, job.id, job.started_at, interrupted)
    else
      Queue.finish(state.queue, job.id, :failed, %{error: interrupted})
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # -- Boot --------------------------------------------------------------------

  defp reap_orphans(state) do
    case Queue.list(state.queue, state: :running, limit: 1_000) do
      {:ok, jobs} ->
        reaped =
          Orphans.reap(jobs,
            signal: state.signal,
            proc_root: state.proc_root,
            grace_ms: state.grace_ms
          )

        if reaped != [],
          do: Logger.warning("killed orphaned mempalace processes: #{inspect(reaped)}")

        {:ok, state}

      {:error, _reason} = error ->
        error
    end
  end

  defp check_legacy(state) do
    if state.legacy_running?.() do
      Process.send_after(self(), :recheck_legacy, state.recheck_ms)
      set_status(state, :blocked)
    else
      set_status(state, :idle)
    end
  end

  # -- Claiming and running ----------------------------------------------------

  defp maybe_claim(%{status: :idle, job: nil} = state) do
    now = now_ms()
    cooldowns = Map.filter(state.cooldowns, fn {_id, until} -> until > now end)
    state = %{state | cooldowns: cooldowns}

    case Queue.claim_next(state.queue, Map.keys(cooldowns)) do
      {:ok, %Job{} = job} -> start_job(state, job)
      {:ok, nil} -> schedule_wake(state)
      {:error, reason} -> retry_later(state, reason)
    end
  end

  defp maybe_claim(state), do: state

  defp start_job(state, %Job{id: id} = job) do
    worker = self()

    run_opts =
      [
        timeout_ms: Kinds.timeout_ms(job.kind, state.timeouts),
        on_start: fn os_pid -> send(worker, {:os_pid, id, os_pid}) end,
        on_output: fn line ->
          Phoenix.PubSub.broadcast(Butler.PubSub, "butler:job:" <> id, {:job_output, id, line})
        end
      ] ++ if(state.palace, do: [palace: state.palace], else: [])

    ctx = %{
      writer: state.writer,
      stop_timeout: state.writer_stop_timeout_ms,
      drain: state.drain_ms
    }

    if Kinds.maintenance?(job.kind) and Maintenance.enter(id) != :ok do
      # The gate cannot be closed: never run, try again after a cooldown.
      error = %{class: "MaintenanceUnavailable", message: "maintenance gate unavailable"}
      Queue.defer(state.queue, id, job.started_at, error)

      schedule_wake(%{
        state
        | cooldowns: Map.put(state.cooldowns, id, now_ms() + state.lock_backoff_ms)
      })
    else
      task =
        Task.Supervisor.async_nolink(state.task_supervisor, fn -> run_job(job, run_opts, ctx) end)

      set_status(
        %{state | job: job, task: task, os_pid: nil, cancelling?: false},
        :running
      )
    end
  end

  # Write MCP jobs go through the persistent writer. Every other job is a CLI
  # job: the writer holds the palace lock after a write, so it is stopped (and
  # gone) before the process starts. This covers maintenance kinds too.
  defp run_job(%Job{kind: kind} = job, run_opts, %{writer: writer}) when kind in @mcp_kinds,
    do: Runner.MCP.run(job, [writer: writer] ++ run_opts)

  # Maintenance: the proxy is already gated (`Maintenance.enter/1`). Drain the
  # requests in flight, then (as for any CLI job) stop the writer and suspend
  # the proxy workers. Maintenance is always left and the proxy resumed, on
  # failure, timeout or crash alike.
  defp run_job(%Job{} = job, run_opts, ctx) do
    if Kinds.maintenance?(job.kind) do
      try do
        _ = MCP.drain(ctx.drain)
        # Re-assert the gate (idempotent): `Maintenance` may have restarted.
        run_cli(job, run_opts, ctx, fn ->
          with :ok <- Maintenance.enter(job.id), do: MCP.suspend()
        end)
      after
        leave_maintenance(job)
      end
    else
      run_cli(job, run_opts, ctx, fn -> :ok end)
    end
  end

  defp run_cli(job, run_opts, %{writer: writer, stop_timeout: stop_timeout}, before_run) do
    case Writer.stop(writer, stop_timeout) do
      :ok ->
        case before_run.() do
          :ok ->
            Runner.CLI.run(job, run_opts)

          {:error, reason} ->
            # Proxy processes may still be alive: never start the CLI.
            {:lock_refused, "MCP proxy could not be suspended: #{inspect(reason)}"}
        end

      {:error, reason} ->
        # The writer may still hold the palace lock: never start the CLI. The
        # job goes back to the queue (attempt refunded) and cools down.
        {:lock_refused, "MCP writer could not be stopped: #{inspect(reason)}"}
    end
  end

  # Idempotent: the run does it in an `after`, this covers a crashed run.
  defp leave_maintenance(%Job{kind: kind}) do
    if Kinds.maintenance?(kind) do
      # Resume first: while the gate is still closed, a request that slips in
      # gets the maintenance error rather than a suspended backend.
      MCP.resume()
      Maintenance.leave()
    end

    :ok
  end

  defp settle(%{job: %Job{} = job} = state, outcome) do
    leave_maintenance(job)

    case finalize(state, job, outcome) do
      {:ok, _job} -> :ok
      other -> Logger.warning("could not settle job #{job.id}: #{inspect(other)}")
    end

    state
    |> then(&%{&1 | job: nil, task: nil, os_pid: nil, cancelling?: false})
    |> add_cooldown(job, outcome)
    |> set_status(:idle)
  end

  defp finalize(%{cancelling?: true} = state, job, _outcome) do
    error = %{class: "Cancelled", message: "cancelled by user"}
    Queue.finish(state.queue, job.id, :cancelled, %{error: error})
  end

  defp finalize(state, job, {:ok, result}),
    do: Queue.finish(state.queue, job.id, :succeeded, %{result: result})

  defp finalize(state, job, {:error, error}),
    do: Queue.finish(state.queue, job.id, :failed, %{error: error})

  defp finalize(state, job, {:lock_refused, output}) do
    seconds = div(state.lock_backoff_ms, 1_000)

    error = %{
      class: Runner.CLI.lock_class(),
      message: "palace lock held by another process; retrying in #{seconds}s",
      output_tail: output
    }

    Queue.defer(state.queue, job.id, job.started_at, error)
  end

  defp add_cooldown(%{cancelling?: true} = state, _job, _outcome), do: state

  defp add_cooldown(state, job, {:lock_refused, _output}),
    do: %{state | cooldowns: Map.put(state.cooldowns, job.id, now_ms() + state.lock_backoff_ms)}

  defp add_cooldown(state, _job, _outcome), do: state

  # Sleeps until the earliest cooldown expires (nothing to do without one).
  defp schedule_wake(%{cooldowns: cooldowns} = state) when map_size(cooldowns) == 0, do: state

  defp schedule_wake(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    delay = max(Enum.min(Map.values(state.cooldowns)) - now_ms(), 0)
    %{state | timer: Process.send_after(self(), :wake, delay)}
  end

  defp retry_later(state, reason) do
    Logger.warning("could not claim a job: #{inspect(reason)}")
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | timer: Process.send_after(self(), :wake, @retry_ms)}
  end

  # -- Cancel and kill ---------------------------------------------------------

  # Known residual race (docs/plan.md, phase 4): for a write MCP job the
  # writer reports its os_pid (`on_start`) just before it sends the request,
  # asynchronously. A cancel arriving in that window is only acted upon once
  # the worker handles `{:os_pid, ...}`, by which time the request may already
  # have been written; the writer is then killed mid-call and the job ends
  # `cancelled`, but the write itself may or may not have been applied.
  defp request_cancel(%{os_pid: nil} = state), do: %{state | cancelling?: true}
  defp request_cancel(state), do: terminate_child(%{state | cancelling?: true})

  # TERM now, KILL after the grace period if the process is still around.
  defp terminate_child(%{os_pid: os_pid, job: %Job{id: id}} = state) do
    state.signal.(os_pid, "TERM")
    Process.send_after(self(), {:kill_grace, id}, state.grace_ms)
    state
  end

  defp schedule_kill(%{os_pid: nil}), do: :ok

  defp schedule_kill(%{os_pid: os_pid} = state),
    do: Process.send_after(self(), {:kill_pid, os_pid}, state.grace_ms)

  # Shutdown: TERM, wait for the task to end, KILL when it does not.
  defp stop_child(%{os_pid: nil}), do: :ok

  defp stop_child(%{os_pid: os_pid, task: %Task{ref: ref}} = state) do
    state.signal.(os_pid, "TERM")

    unless await_task(ref, state.grace_ms) do
      state.signal.(os_pid, "KILL")
      await_task(ref, 1_000)
    end

    :ok
  end

  defp await_task(ref, timeout) do
    receive do
      {^ref, _outcome} -> true
      {:DOWN, ^ref, :process, _pid, _reason} -> true
    after
      timeout -> false
    end
  end

  defp drain_os_pid(%{job: %Job{id: id}} = state) do
    receive do
      {:os_pid, ^id, os_pid} -> %{state | os_pid: os_pid}
    after
      0 -> state
    end
  end

  # -- Helpers -----------------------------------------------------------------

  defp set_status(%{status: status} = state, status), do: state

  defp set_status(state, status) do
    Phoenix.PubSub.broadcast(Butler.PubSub, @topic, {:worker_changed, status})
    %{state | status: status}
  end

  defp active_id(%{job: %Job{id: id}}), do: id
  defp active_id(_state), do: nil

  defp now_ms, do: System.monotonic_time(:millisecond)
end
