defmodule Butler.MCP.Backend do
  @moduledoc """
  State machine of one MCP backend (`:full` or `:light`).

  A backend keeps **two** `Butler.MCP.Worker` processes: the *active* one
  serves requests, the other one is a *standby*, already warm. Callers
  `checkout/1` the active worker and talk to it directly, so requests never
  go through this process.

  ## Rotation

  After `:idle_rotation_ms` without a checkout, the standby becomes the
  active worker, the old active process is killed (which gives its memory
  back to the OS) and a new standby is started. The rotation happens even
  when nobody used the backend.

  ## Crashes and failures

  When the active worker dies, the standby takes over at once and a new
  standby is started. Requests that were in flight fail immediately; nothing
  is retried.

  Start-up failures (missing binary, exit before the handshake, handshake
  timeout) are counted. After `:max_start_failures` of them in a row, and if
  no worker is active, the backend is `:failed`: Butler stops retrying and
  checkouts fail with `{:error, {:failed, reason}}`. A worker reaching the
  ready state resets the counter, and so does `restart/1`.

  ## Status

    * `:starting` - no worker is active yet
    * `:ready` - an active worker and a ready standby
    * `:degraded` - an active worker, but no ready standby
    * `:failed` - gave up starting workers

  Every change of state broadcasts `{:mcp_changed, id}` on the PubSub topic.
  """

  use GenServer

  alias Butler.MCP.Config
  alias Butler.MCP.Worker

  @default_topic "butler:mcp"
  @workers_target 2
  @busy_retry_ms 1_000

  @type status :: :starting | :ready | :degraded | :failed

  @typedoc "A live worker, as shown to the UI."
  @type worker_view :: %{
          pid: pid(),
          os_pid: non_neg_integer() | nil,
          started_at: integer()
        }

  @type snapshot :: %{
          id: Config.backend() | term(),
          status: status(),
          active: worker_view() | nil,
          standby: worker_view() | nil,
          starting: non_neg_integer(),
          failures: non_neg_integer(),
          last_error: term(),
          next_rotation_at: integer() | nil,
          idle_rotation_ms: pos_integer(),
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
    active: nil,
    failed?: false,
    failures: 0,
    waiters: %{},
    requests: 0,
    errors: 0,
    rotations: 0
  ]

  @doc """
  Starts a backend.

  Options: `:id` and `:worker_supervisor` (required), `:name`, `:bin`,
  `:args`, `:env`, `:idle_rotation_ms`, `:max_start_failures`,
  `:request_timeout_ms`, `:startup_timeout_ms` (defaults from
  `Butler.MCP.Config`), `:topic` and `:pubsub`.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    gen_opts = if name = Keyword.get(opts, :name), do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Returns the active worker and counts one request.

  While no worker is active yet, the call waits for one, up to the start-up
  timeout.
  """
  @spec checkout(GenServer.server()) ::
          {:ok, pid()} | {:error, :unavailable | {:failed, term()}}
  def checkout(server), do: GenServer.call(server, :checkout, :infinity)

  @doc "Counts one failed request."
  @spec record_error(GenServer.server()) :: :ok
  def record_error(server), do: GenServer.cast(server, :record_error)

  @doc "A snapshot of the backend, for display."
  @spec status(GenServer.server()) :: snapshot()
  def status(server), do: GenServer.call(server, :status)

  @doc """
  Forces a rotation now. When no standby is ready (or when the backend is
  failed), every worker is replaced by fresh ones. The failure counter is
  reset.
  """
  @spec restart(GenServer.server()) :: :ok
  def restart(server), do: GenServer.call(server, :restart)

  @doc "The PubSub topic backends broadcast on."
  @spec topic() :: String.t()
  def topic, do: @default_topic

  @impl GenServer
  def init(opts) do
    state = %__MODULE__{
      id: Keyword.fetch!(opts, :id),
      worker_supervisor: Keyword.fetch!(opts, :worker_supervisor),
      bin: Keyword.get_lazy(opts, :bin, fn -> Config.bin(Keyword.fetch!(opts, :id)) end),
      args: Keyword.get_lazy(opts, :args, fn -> Config.args(Keyword.fetch!(opts, :id)) end),
      env: Keyword.get(opts, :env, Config.env()),
      task_supervisor: Keyword.get(opts, :task_supervisor, Butler.TaskSupervisor),
      pubsub: Keyword.get(opts, :pubsub, Butler.PubSub),
      topic: Keyword.get(opts, :topic, @default_topic),
      idle_ms: Keyword.get_lazy(opts, :idle_rotation_ms, &Config.idle_rotation_ms/0),
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
  def handle_call(:checkout, _from, %{active: active} = state) when is_pid(active) do
    {:reply, {:ok, active}, state |> count_request() |> schedule_rotation()}
  end

  def handle_call(:checkout, _from, %{failed?: true} = state) do
    {:reply, {:error, {:failed, state.last_error}}, state}
  end

  def handle_call(:checkout, from, state) do
    token = make_ref()
    timer = Process.send_after(self(), {:waiter_timeout, token}, state.startup_timeout_ms)
    {:noreply, %{state | waiters: Map.put(state.waiters, token, {from, timer})}}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  def handle_call(:restart, _from, state) do
    state = %{state | failures: 0, last_error: nil, failed?: false}

    state =
      if state.active && ready_standby(state) do
        rotate(state, true)
      else
        state |> replace_all_workers() |> ensure_workers()
      end

    {:reply, :ok, broadcast(state)}
  end

  @impl GenServer
  def handle_cast(:record_error, state), do: {:noreply, %{state | errors: state.errors + 1}}

  @impl GenServer
  def handle_info({:mcp_worker, pid, :ready}, state) do
    case state.workers do
      %{^pid => meta} ->
        workers = Map.put(state.workers, pid, %{meta | phase: :ready, os_pid: os_pid(pid)})
        state = %{state | workers: workers, failures: 0, last_error: nil}
        state = if state.active, do: state, else: promote(state, pid)
        {:noreply, state |> ensure_workers() |> broadcast()}

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
    {:noreply, state |> Map.put(:rotation_timer, nil) |> rotate(false) |> broadcast()}
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

  # -- workers ----------------------------------------------------------

  defp ensure_workers(%{failed?: true} = state), do: state

  defp ensure_workers(%{failures: failures, max_failures: max} = state) when failures >= max do
    state
  end

  defp ensure_workers(state) do
    Enum.reduce(1..@workers_target//1, state, &spawn_missing_worker/2)
  end

  defp spawn_missing_worker(_slot, state) do
    if map_size(state.workers) < @workers_target, do: spawn_worker(state), else: state
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
          started_at: System.system_time(:millisecond)
        }

        %{state | workers: Map.put(state.workers, pid, meta)}

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
        state = if state.active == pid, do: lose_active(state), else: state
        state = if phase == :starting, do: %{state | failures: state.failures + 1}, else: state

        state
        |> ensure_workers()
        |> fail_if_exhausted()
        |> broadcast()
    end
  end

  defp lose_active(state) do
    state = cancel_rotation(%{state | active: nil})

    case ready_standby(state) do
      nil -> state
      pid -> promote(state, pid)
    end
  end

  defp promote(state, pid) do
    state = %{state | active: pid} |> schedule_rotation()

    Enum.each(state.waiters, fn {_token, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:ok, pid})
    end)

    %{state | waiters: %{}, requests: state.requests + map_size(state.waiters)}
  end

  defp fail_if_exhausted(%{active: nil, failures: failures, max_failures: max} = state)
       when failures >= max do
    Enum.each(Map.keys(state.workers), &stop_async(state, &1))

    Enum.each(state.waiters, fn {_token, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, {:failed, state.last_error}})
    end)

    %{cancel_rotation(state) | failed?: true, workers: %{}, waiters: %{}}
  end

  defp fail_if_exhausted(state), do: state

  defp replace_all_workers(state) do
    Enum.each(state.workers, fn {pid, meta} ->
      Process.demonitor(meta.ref, [:flush])
      stop_async(state, pid)
    end)

    cancel_rotation(%{state | workers: %{}, active: nil})
  end

  defp stop_async(state, pid) do
    {:ok, _pid} = Task.Supervisor.start_child(state.task_supervisor, fn -> Worker.stop(pid) end)
    :ok
  end

  defp ready_standby(state) do
    Enum.find_value(state.workers, fn
      {pid, %{phase: :ready}} when pid != state.active -> pid
      _other -> nil
    end)
  end

  defp os_pid(pid) do
    Worker.info(pid).os_pid
  catch
    :exit, _reason -> nil
  end

  defp busy?(pid) do
    Worker.info(pid).pending > 0
  catch
    :exit, _reason -> false
  end

  # -- rotation ---------------------------------------------------------

  defp rotate(state, force?) do
    standby = ready_standby(state)

    cond do
      is_nil(state.active) ->
        state

      is_nil(standby) ->
        schedule_rotation(state)

      not force? and busy?(state.active) ->
        schedule_rotation(state, min(state.idle_ms, @busy_retry_ms))

      true ->
        swap(state, standby)
    end
  end

  defp swap(state, standby) do
    {meta, workers} = Map.pop(state.workers, state.active)
    Process.demonitor(meta.ref, [:flush])
    stop_async(state, state.active)

    %{state | workers: workers, active: standby, rotations: state.rotations + 1}
    |> schedule_rotation()
    |> ensure_workers()
  end

  defp schedule_rotation(state, delay \\ nil) do
    state = cancel_rotation(state)
    delay = delay || state.idle_ms
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
    standby = ready_standby(state)

    %{
      id: state.id,
      status: status_of(state, standby),
      active: view(state, state.active),
      standby: view(state, standby),
      starting: Enum.count(state.workers, fn {_pid, meta} -> meta.phase == :starting end),
      failures: state.failures,
      last_error: state.last_error,
      next_rotation_at: state.next_rotation_at,
      idle_rotation_ms: state.idle_ms,
      requests: state.requests,
      errors: state.errors,
      rotations: state.rotations
    }
  end

  defp status_of(%{failed?: true}, _standby), do: :failed
  defp status_of(%{active: nil}, _standby), do: :starting
  defp status_of(_state, nil), do: :degraded
  defp status_of(_state, _standby), do: :ready

  defp view(_state, nil), do: nil

  defp view(state, pid) do
    meta = Map.fetch!(state.workers, pid)
    %{pid: pid, os_pid: meta.os_pid, started_at: meta.started_at}
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(state.pubsub, state.topic, {:mcp_changed, state.id})
    state
  end
end
