defmodule Butler.MCP.Backend do
  @moduledoc """
  State machine of one MCP backend (`:full` or `:light`).

  A backend keeps a **pool** of `:pool_size` `Butler.MCP.Worker` processes
  (`Butler.MCP.Config.pool_size/0`). Callers `checkout/1` a ready worker and
  talk to it directly, so requests never go through this process. Workers are
  handed out in **round-robin** order: a Python process handles its requests
  one after the other, so spreading them is what makes the pool faster than a
  single process.

  ## Rotation

  After `:idle_rotation_ms` without a checkout, **every** worker of the pool
  is replaced at once by fresh ones (which gives the memory of the old
  processes back to the OS). The rotation happens even when nobody used the
  backend, and is postponed while a request is in flight. Requests arriving
  while the new workers start wait for the first ready one. With
  `idle_rotation_ms: 0` there is no automatic rotation at all; `restart/1`
  still replaces the whole pool.

  ## Crashes and failures

  When a worker dies, only that worker is replaced. Requests that were in
  flight on it fail immediately; nothing is retried.

  Start-up failures (missing binary, exit before the handshake, handshake
  timeout) are counted. After `:max_start_failures` of them in a row, and if
  no worker is ready, the backend is `:failed`: Butler stops retrying and
  checkouts fail with `{:error, {:failed, reason}}`. A worker reaching the
  ready state resets the counter, and so does `restart/1`.

  ## Status

    * `:starting` - no worker is ready yet
    * `:ready` - all `:pool_size` workers are ready
    * `:degraded` - some, but not all, workers are ready
    * `:failed` - gave up starting workers

    * `:suspended` - maintenance: every worker is stopped (`suspend/2`) and
      none is started until `resume/1`; checkouts fail with
      `{:error, :suspended}`

  Every change of state broadcasts `{:mcp_changed, id}` on the PubSub topic.
  """

  use GenServer

  alias Butler.MCP.Config
  alias Butler.MCP.Worker

  @default_topic "butler:mcp"
  @busy_retry_ms 1_000

  @suspend_timeout_ms 60_000
  @drain_poll_ms 50

  @type status :: :starting | :ready | :degraded | :failed | :suspended

  @typedoc "A live worker, as shown to the UI."
  @type worker_view :: %{
          pid: pid(),
          os_pid: non_neg_integer() | nil,
          started_at: integer(),
          phase: :starting | :ready,
          pending: non_neg_integer()
        }

  @type snapshot :: %{
          id: Config.backend() | term(),
          status: status(),
          workers: [worker_view()],
          pool_size: pos_integer(),
          ready: non_neg_integer(),
          starting: non_neg_integer(),
          failures: non_neg_integer(),
          last_error: term(),
          next_rotation_at: integer() | nil,
          idle_rotation_ms: non_neg_integer(),
          requests: non_neg_integer(),
          errors: non_neg_integer(),
          rotations: non_neg_integer()
        }

  defstruct [
    :id,
    :bin,
    :worker_supervisor,
    :task_supervisor,
    :pubsub,
    :topic,
    :idle_ms,
    :pool_size,
    :max_failures,
    :request_timeout_ms,
    :startup_timeout_ms,
    :last_error,
    :rotation_timer,
    :rotation_token,
    :next_rotation_at,
    args: [],
    env: %{},
    workers: %{},
    spawned: 0,
    cursor: 0,
    failed?: false,
    suspended?: false,
    failures: 0,
    waiters: %{},
    requests: 0,
    errors: 0,
    rotations: 0
  ]

  @doc """
  Starts a backend.

  Options: `:id` and `:worker_supervisor` (required), `:name`, `:bin`,
  `:args`, `:env`, `:pool_size`, `:idle_rotation_ms` (`0`: no rotation),
  `:max_start_failures`, `:request_timeout_ms`, `:startup_timeout_ms`
  (defaults from `Butler.MCP.Config`), `:topic` and `:pubsub`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    gen_opts = if name = Keyword.get(opts, :name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Returns the next ready worker (round-robin) and counts one request.

  While no worker is ready yet, the call waits for one, up to the start-up
  timeout.
  """
  @spec checkout(GenServer.server()) ::
          {:ok, pid()} | {:error, :unavailable | :suspended | {:failed, term()}}
  def checkout(server), do: GenServer.call(server, :checkout, :infinity)

  @doc "Counts one failed request."
  @spec record_error(GenServer.server()) :: :ok
  def record_error(server), do: GenServer.cast(server, :record_error)

  @doc "A snapshot of the backend, for display."
  @spec status(GenServer.server()) :: snapshot()
  def status(server), do: GenServer.call(server, :status)

  @doc """
  Forces a rotation now: every worker is replaced by fresh ones, even when
  the automatic rotation is off or the backend is failed. Requests in flight
  fail. The failure counter is reset.
  """
  @spec restart(GenServer.server()) :: :ok
  def restart(server), do: GenServer.call(server, :restart)

  @doc """
  Waits until no request is in flight on the workers of the backend, at most
  `timeout` ms. Returns `:timeout` when requests are still pending.
  """
  @spec drain(GenServer.server(), non_neg_integer()) :: :ok | :timeout
  def drain(server, timeout) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_drain(server, deadline)
  end

  defp do_drain(server, deadline) do
    snapshot = status(server)

    cond do
      Enum.all?(snapshot.workers, &(&1.pending == 0)) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :timeout

      true ->
        Process.sleep(@drain_poll_ms)
        do_drain(server, deadline)
    end
  end

  @doc """
  Maintenance: stops every worker (waiting until their OS processes are
  gone) and starts none until `resume/1`. Requests in flight fail; waiting
  checkouts get `{:error, :unavailable}`. Idempotent.
  """
  @spec suspend(GenServer.server()) :: :ok
  def suspend(server), do: GenServer.call(server, :suspend, @suspend_timeout_ms)

  @doc "Ends a suspension: starts fresh workers. Idempotent; resets the failure counter."
  @spec resume(GenServer.server()) :: :ok
  def resume(server), do: GenServer.call(server, :resume)

  @doc "The PubSub topic backends broadcast on."
  @spec topic() :: String.t()
  def topic, do: @default_topic

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      worker_supervisor: Keyword.fetch!(opts, :worker_supervisor),
      bin: Keyword.get_lazy(opts, :bin, fn -> Config.bin(Keyword.fetch!(opts, :id)) end),
      args: Keyword.get(opts, :args, []),
      env: Keyword.get(opts, :env, Config.env()),
      task_supervisor: Keyword.get(opts, :task_supervisor, Butler.TaskSupervisor),
      pubsub: Keyword.get(opts, :pubsub, Butler.PubSub),
      topic: Keyword.get(opts, :topic, @default_topic),
      idle_ms: Keyword.get_lazy(opts, :idle_rotation_ms, &Config.idle_rotation_ms/0),
      pool_size: Keyword.get_lazy(opts, :pool_size, &Config.pool_size/0),
      max_failures: Keyword.get_lazy(opts, :max_start_failures, &Config.max_start_failures/0),
      request_timeout_ms:
        Keyword.get_lazy(opts, :request_timeout_ms, &Config.request_timeout_ms/0),
      startup_timeout_ms:
        Keyword.get_lazy(opts, :startup_timeout_ms, &Config.startup_timeout_ms/0)
    }

    {:ok, state, {:continue, :boot}}
  end

  @impl GenServer
  def handle_continue(:boot, state) do
    {:noreply, state |> ensure_workers() |> broadcast()}
  end

  @impl GenServer
  def handle_call(:checkout, from, state) do
    case ready_pids(state) do
      [] ->
        checkout_unavailable(from, state)

      ready ->
        {pid, state} = pick(state, ready)
        {:reply, {:ok, pid}, state |> count_request() |> schedule_rotation()}
    end
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:suspend, _from, state) do
    {:reply, :ok, state |> suspend_workers() |> broadcast()}
  end

  def handle_call(:resume, _from, %{suspended?: false} = state), do: {:reply, :ok, state}

  def handle_call(:resume, _from, state) do
    state = %{state | suspended?: false, failures: 0, last_error: nil, failed?: false}
    {:reply, :ok, state |> ensure_workers() |> broadcast()}
  end

  def handle_call(:restart, _from, state) do
    state = %{state | failures: 0, last_error: nil, failed?: false}
    {:reply, :ok, state |> replace_pool() |> broadcast()}
  end

  @impl GenServer
  def handle_cast(:record_error, state), do: {:noreply, %{state | errors: state.errors + 1}}

  @impl GenServer
  def handle_info({:mcp_worker, pid, :ready}, state) do
    case state.workers do
      %{^pid => meta} ->
        workers = Map.put(state.workers, pid, %{meta | phase: :ready, os_pid: os_pid(pid)})
        state = %{state | workers: workers, failures: 0, last_error: nil}

        {:noreply,
         state |> serve_waiters() |> ensure_workers() |> ensure_rotation() |> broadcast()}

      _unknown ->
        {:noreply, state}
    end
  end

  def handle_info({:mcp_worker, pid, {:exited, phase, reason}}, state) do
    {:noreply, worker_gone(state, pid, phase, reason)}
  end

  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case state.workers do
      %{^pid => meta} -> {:noreply, worker_gone(state, pid, meta.phase, {:crashed, reason})}
      _unknown -> {:noreply, state}
    end
  end

  def handle_info({:rotate, token}, %{rotation_token: token} = state) do
    {:noreply, state |> Map.put(:rotation_timer, nil) |> rotate() |> broadcast()}
  end

  def handle_info({:waiter_timeout, token}, state) do
    case Map.pop(state.waiters, token) do
      {{from, _timer}, waiters} ->
        GenServer.reply(from, {:error, :unavailable})
        {:noreply, %{state | waiters: waiters}}

      {nil, _waiters} ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  # -- checkout ---------------------------------------------------------

  defp checkout_unavailable(_from, %{suspended?: true} = state) do
    {:reply, {:error, :suspended}, state}
  end

  defp checkout_unavailable(_from, %{failed?: true} = state) do
    {:reply, {:error, {:failed, state.last_error}}, state}
  end

  defp checkout_unavailable(from, state) do
    token = make_ref()
    timer = Process.send_after(self(), {:waiter_timeout, token}, state.startup_timeout_ms)
    {:noreply, %{state | waiters: Map.put(state.waiters, token, {from, timer})}}
  end

  # Round-robin. The only place that decides which worker serves a request.
  defp pick(state, ready) do
    pid = Enum.at(ready, rem(state.cursor, length(ready)))
    {pid, %{state | cursor: state.cursor + 1}}
  end

  # Ready workers, in the order they were started (a stable round-robin).
  defp ready_pids(state) do
    state.workers
    |> Enum.filter(fn {_pid, meta} -> meta.phase == :ready end)
    |> Enum.sort_by(fn {_pid, meta} -> meta.seq end)
    |> Enum.map(fn {pid, _meta} -> pid end)
  end

  defp serve_waiters(%{waiters: waiters} = state) when map_size(waiters) == 0, do: state

  defp serve_waiters(state) do
    ready = ready_pids(state)

    state =
      Enum.reduce(state.waiters, state, fn {_token, {from, timer}}, acc ->
        Process.cancel_timer(timer)
        {pid, acc} = pick(acc, ready)
        GenServer.reply(from, {:ok, pid})
        count_request(acc)
      end)

    %{state | waiters: %{}}
  end

  # -- workers ----------------------------------------------------------

  defp ensure_workers(%{suspended?: true} = state), do: state
  defp ensure_workers(%{failed?: true} = state), do: state

  defp ensure_workers(%{failures: failures, max_failures: max} = state) when failures >= max do
    state
  end

  defp ensure_workers(state) do
    Enum.reduce(1..state.pool_size//1, state, &spawn_missing_worker/2)
  end

  defp spawn_missing_worker(_slot, state) do
    if map_size(state.workers) < state.pool_size, do: spawn_worker(state), else: state
  end

  defp spawn_worker(state) do
    opts = [
      bin: state.bin,
      args: state.args,
      env: state.env,
      owner: self(),
      request_timeout_ms: state.request_timeout_ms,
      startup_timeout_ms: state.startup_timeout_ms
    ]

    case DynamicSupervisor.start_child(state.worker_supervisor, {Worker, opts}) do
      {:ok, pid} ->
        meta = %{
          phase: :starting,
          os_pid: nil,
          ref: Process.monitor(pid),
          seq: state.spawned,
          started_at: System.system_time(:millisecond)
        }

        %{state | workers: Map.put(state.workers, pid, meta), spawned: state.spawned + 1}

      {:error, reason} ->
        %{state | failures: state.failures + 1, last_error: {:cannot_start, reason}}
    end
  end

  defp worker_gone(state, pid, phase, reason) do
    case Map.pop(state.workers, pid) do
      {nil, _workers} ->
        state

      {meta, workers} ->
        Process.demonitor(meta.ref, [:flush])
        state = %{state | workers: workers, last_error: reason}
        state = if phase == :starting, do: %{state | failures: state.failures + 1}, else: state

        state
        |> ensure_workers()
        |> fail_if_exhausted()
        |> pause_rotation_if_idle_pool()
        |> broadcast()
    end
  end

  defp fail_if_exhausted(%{failures: failures, max_failures: max} = state) when failures >= max do
    if ready_pids(state) == [], do: fail(state), else: state
  end

  defp fail_if_exhausted(state), do: state

  defp fail(state) do
    Enum.each(Map.keys(state.workers), &stop_async(state, &1))

    Enum.each(state.waiters, fn {_token, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, {:failed, state.last_error}})
    end)

    %{cancel_rotation(state) | failed?: true, workers: %{}, waiters: %{}}
  end

  defp suspend_workers(state) do
    Enum.each(state.workers, fn {pid, meta} ->
      Process.demonitor(meta.ref, [:flush])
      Worker.stop(pid)
    end)

    Enum.each(state.waiters, fn {_token, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :unavailable})
    end)

    state = cancel_rotation(state)
    %{state | workers: %{}, waiters: %{}, suspended?: true}
  end

  # Replaces every worker with a fresh one. Counts a rotation when there was
  # something to replace.
  defp replace_pool(state) do
    rotations = if map_size(state.workers) > 0, do: state.rotations + 1, else: state.rotations

    state
    |> replace_all_workers()
    |> Map.put(:rotations, rotations)
    |> ensure_workers()
  end

  defp replace_all_workers(state) do
    Enum.each(state.workers, fn {pid, meta} ->
      Process.demonitor(meta.ref, [:flush])
      stop_async(state, pid)
    end)

    cancel_rotation(%{state | workers: %{}})
  end

  defp stop_async(state, pid) do
    {:ok, _pid} = Task.Supervisor.start_child(state.task_supervisor, fn -> Worker.stop(pid) end)
    :ok
  end

  defp os_pid(pid) do
    Worker.info(pid).os_pid
  catch
    :exit, _reason -> nil
  end

  defp pending(pid) do
    Worker.info(pid).pending
  catch
    :exit, _reason -> 0
  end

  # -- rotation ---------------------------------------------------------

  # Automatic rotation: the whole pool, unless a request is in flight.
  defp rotate(state) do
    ready = ready_pids(state)

    cond do
      ready == [] -> schedule_rotation(state)
      Enum.any?(ready, &(pending(&1) > 0)) -> schedule_rotation(state, @busy_retry_ms)
      true -> replace_pool(state)
    end
  end

  # Arms the timer when workers are ready and none is armed yet.
  defp ensure_rotation(%{rotation_timer: nil} = state) do
    if ready_pids(state) == [], do: state, else: schedule_rotation(state)
  end

  defp ensure_rotation(state), do: state

  defp pause_rotation_if_idle_pool(state) do
    if ready_pids(state) == [], do: cancel_rotation(state), else: state
  end

  defp schedule_rotation(state, delay \\ nil)

  defp schedule_rotation(%{idle_ms: 0} = state, _delay), do: state

  defp schedule_rotation(state, delay) do
    state = cancel_rotation(state)
    delay = if delay, do: min(delay, state.idle_ms), else: state.idle_ms
    token = make_ref()

    %{
      state
      | rotation_token: token,
        rotation_timer: Process.send_after(self(), {:rotate, token}, delay),
        next_rotation_at: System.system_time(:millisecond) + delay
    }
  end

  defp cancel_rotation(%{rotation_timer: nil} = state), do: %{state | next_rotation_at: nil}

  defp cancel_rotation(state) do
    Process.cancel_timer(state.rotation_timer)
    %{state | rotation_timer: nil, rotation_token: nil, next_rotation_at: nil}
  end

  # -- reporting --------------------------------------------------------

  defp count_request(state), do: %{state | requests: state.requests + 1}

  defp snapshot(state) do
    workers = views(state)
    ready = Enum.count(workers, &(&1.phase == :ready))

    %{
      id: state.id,
      status: status_of(state, ready),
      workers: workers,
      pool_size: state.pool_size,
      ready: ready,
      starting: length(workers) - ready,
      failures: state.failures,
      last_error: state.last_error,
      next_rotation_at: state.next_rotation_at,
      idle_rotation_ms: state.idle_ms,
      requests: state.requests,
      errors: state.errors,
      rotations: state.rotations
    }
  end

  defp status_of(%{suspended?: true}, _ready), do: :suspended
  defp status_of(%{failed?: true}, _ready), do: :failed
  defp status_of(_state, 0), do: :starting
  defp status_of(%{pool_size: size}, ready) when ready < size, do: :degraded
  defp status_of(_state, _ready), do: :ready

  defp views(state) do
    state.workers
    |> Enum.sort_by(fn {_pid, meta} -> meta.seq end)
    |> Enum.map(fn {pid, meta} ->
      %{
        pid: pid,
        os_pid: meta.os_pid,
        started_at: meta.started_at,
        phase: meta.phase,
        pending: if(meta.phase == :ready, do: pending(pid), else: 0)
      }
    end)
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(state.pubsub, state.topic, {:mcp_changed, state.id})
    state
  end
end
