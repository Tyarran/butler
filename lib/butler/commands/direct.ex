defmodule Butler.Commands.Direct do
  @moduledoc """
  Runs the *direct* maintenance commands (`repair`, `compress`,
  `migrate-wings`), which must not run while the daemon is up.

  A run goes through these steps, in this order:

    1. **guard** - refused when jobs block (`Butler.Commands.Guard`);
    2. **stop** the daemon and **wait** until it is really stopped (skipped if
       it was already stopped);
    3. **verify** that the daemon is stopped and **re-check the guard**: if a
       job appeared meanwhile the run is aborted;
    4. **command** - only now, with the output streamed line by line;
    5. **restart** the daemon, in an `after` block: it happens even when the
       command fails, times out or raises. The daemon is only restarted if it
       was running when the run began (its previous state is restored).

  Only one run can be in progress at a time (`{:error, :busy}` otherwise).

  ## Events

  Subscribe to `topic/1` *before* calling `start_run/2` (pass a `:run_id`
  from `new_run_id/0`). Messages are `{:direct, run_id, event}` with `event`:

    * `{:step, :stopping | :waiting | :running | :restarting}`
    * `{:line, text}` - one line of command output
    * `{:restart, :ok | {:error, reason}}`
    * `{:done, result}` - `{:ok, %{status: 0}}` or `{:error, reason}`

  > #### Killing the worker {: .warning}
  > An untrappable kill of the worker process skips the `after` block. The
  > lock is still released and a `{:done, {:error, {:crashed, reason}}}` event
  > is broadcast, but the daemon is not restarted.
  """

  use GenServer

  alias Butler.CLI
  alias Butler.Commands.Guard
  alias Butler.Daemon.Control
  alias Butler.Daemon.Status
  alias Butler.Palace

  @commands [:repair, :compress, :migrate_wings]
  @command_timeout_ms 1_800_000
  @run_id_bytes 9
  @topic_prefix "butler:direct:"

  @type command :: :repair | :compress | :migrate_wings
  @type run_id :: String.t()

  @type start_error ::
          :busy
          | :unknown_command
          | {:blocked, [Butler.Jobs.Job.t()]}
          | {:guard, term()}

  # Client API

  @doc "Starts the lock server."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @doc "The supported commands."
  @spec commands() :: [command()]
  def commands, do: @commands

  @doc "A fresh run id."
  @spec new_run_id() :: run_id()
  def new_run_id,
    do: @run_id_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

  @doc "PubSub topic of a run."
  @spec topic(run_id()) :: String.t()
  def topic(run_id), do: @topic_prefix <> run_id

  @doc "The id of the run in progress, or `nil`."
  @spec running() :: run_id() | nil
  def running, do: GenServer.call(__MODULE__, :running)

  @doc """
  Starts a run in the background.

  Options: `:dry_run` (default `false`), `:run_id`, and, mainly for tests,
  `:guard` (0-arity function), `:status` (0-arity function returning a
  `Butler.Daemon.Status`) and `:control_opts` (see `Butler.Daemon.Control`).
  """
  @spec start_run(command() | atom(), keyword()) :: {:ok, run_id()} | {:error, start_error()}
  def start_run(command, opts \\ []), do: GenServer.call(__MODULE__, {:start_run, command, opts})

  # Server

  @impl GenServer
  def init(:ok), do: {:ok, %{run: nil}}

  @impl GenServer
  def handle_call(:running, _from, state), do: {:reply, state.run && state.run.id, state}

  def handle_call({:start_run, _command, _opts}, _from, %{run: %{}} = state),
    do: {:reply, {:error, :busy}, state}

  def handle_call({:start_run, command, opts}, _from, state) do
    with {:ok, args} <- command_args(command, Keyword.get(opts, :dry_run, false)),
         :ok <- check_guard(opts) do
      run_id = Keyword.get_lazy(opts, :run_id, &new_run_id/0)
      ctx = context(run_id, args, opts)

      {:ok, pid} = Task.Supervisor.start_child(Butler.TaskSupervisor, fn -> execute(ctx) end)
      ref = Process.monitor(pid)

      {:reply, {:ok, run_id}, %{state | run: %{id: run_id, ref: ref}}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{run: %{ref: ref, id: id}} = state) do
    if reason != :normal do
      broadcast(id, {:done, {:error, {:crashed, reason}}})
    end

    {:noreply, %{state | run: nil}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # Commands

  defp command_args(:repair, true), do: {:ok, ["repair", "--dry-run"]}
  defp command_args(:repair, _), do: {:ok, ["repair", "--yes"]}
  defp command_args(:compress, true), do: {:ok, ["compress", "--dry-run"]}
  defp command_args(:compress, _), do: {:ok, ["compress"]}
  defp command_args(:migrate_wings, true), do: {:ok, ["migrate-wings", "--dry-run"]}
  defp command_args(:migrate_wings, _), do: {:ok, ["migrate-wings", "--yes"]}
  defp command_args(_command, _dry_run), do: {:error, :unknown_command}

  defp check_guard(opts) do
    guard = Keyword.get(opts, :guard, &Guard.check/0)

    case guard.() do
      :ok -> :ok
      {:blocked, jobs} -> {:error, {:blocked, jobs}}
      {:error, reason} -> {:error, {:guard, reason}}
    end
  end

  defp context(run_id, args, opts) do
    status = Keyword.get(opts, :status, &Status.resolve/0)

    control_opts =
      :butler
      |> Application.get_env(:control_opts, [])
      |> Keyword.merge(Keyword.get(opts, :control_opts, []))
      |> Keyword.put_new(:status, status)

    %{
      run_id: run_id,
      args: ["--palace", Palace.path() | args],
      guard: Keyword.get(opts, :guard, &Guard.check/0),
      status: status,
      control_opts: control_opts
    }
  end

  # Worker

  defp execute(ctx) do
    was_running? = ctx.status.().state == :running

    outcome =
      try do
        run_steps(ctx, was_running?)
      rescue
        exception -> {:error, {:exception, Exception.message(exception)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      after
        if was_running?, do: restart(ctx)
      end

    emit(ctx, {:done, outcome})
  end

  defp run_steps(ctx, was_running?) do
    with :ok <- stop_daemon(ctx, was_running?),
         :ok <- verify_stopped(ctx),
         :ok <- recheck_guard(ctx) do
      run_command(ctx)
    end
  end

  defp stop_daemon(_ctx, false), do: :ok

  defp stop_daemon(ctx, true) do
    emit(ctx, {:step, :stopping})

    case Control.stop(ctx.control_opts) do
      {:ok, _output} ->
        emit(ctx, {:step, :waiting})
        Control.wait_stopped(ctx.control_opts)

      {:error, reason} ->
        {:error, {:stop_failed, reason}}
    end
  end

  defp verify_stopped(ctx) do
    if ctx.status.().state == :stopped, do: :ok, else: {:error, :not_stopped}
  end

  defp recheck_guard(ctx) do
    case ctx.guard.() do
      :ok -> :ok
      {:blocked, jobs} -> {:error, {:blocked, jobs}}
      {:error, reason} -> {:error, {:guard, reason}}
    end
  end

  defp run_command(ctx) do
    emit(ctx, {:step, :running})
    on_output = fn line -> emit(ctx, {:line, line}) end

    case CLI.run(ctx.args, timeout: @command_timeout_ms, on_output: on_output) do
      {:ok, %{status: 0}} -> {:ok, %{status: 0}}
      {:ok, %{status: status}} -> {:error, {:exit_status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp restart(ctx) do
    emit(ctx, {:step, :restarting})

    result =
      case Control.start(ctx.control_opts) do
        {:ok, _output} -> :ok
        {:error, _reason} = error -> error
      end

    emit(ctx, {:restart, result})
  end

  defp emit(ctx, event), do: broadcast(ctx.run_id, event)

  defp broadcast(run_id, event) do
    Phoenix.PubSub.broadcast(Butler.PubSub, topic(run_id), {:direct, run_id, event})
  end
end
