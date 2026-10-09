defmodule Butler.MCP.Writer do
  @moduledoc """
  The persistent *full* `mempalace-mcp` process that executes queued write
  jobs (`mcp_tool`, `diary_write`).

  A full MCP process keeps the palace lock after its first write until it
  exits (`docs/spikes.md`, Q1), which would refuse every CLI job. Hence:

    * it is started **lazily** by the first `call_tool/3`;
    * it is **never stopped on idle** (`MEMPALACE_MCP_IDLE_HOURS=0` also
      disables MemPalace's own idle exit; there is no timer here);
    * it is **always stopped** with `stop/1` before every CLI job (the job
      worker does it) and before maintenance; the next write restarts it cold;
    * a request that times out, or a process that dies, discards the process:
      a request is never retried.

  It reuses `Butler.MCP.Worker` (same executable, `Butler.MCP.Config.env/0`,
  kill by `os_pid`). The proxy workers never write, so they do not hold the
  lock.

  Options (mostly for tests): `:name`, `:bin`, `:args`, `:env` (merged over
  `Butler.MCP.Config.env/0`), `:startup_timeout_ms`.
  """

  use GenServer

  alias Butler.MCP.Config
  alias Butler.MCP.Protocol
  alias Butler.MCP.Worker

  @call_timeout_ms 600_000
  @stop_timeout_ms 30_000

  @type error ::
          :timeout
          | {:start_failed, term()}
          | {:backend_exited, integer()}
          | Worker.call_error()

  @doc "Starts the writer (without starting its process: that is lazy)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Calls the MCP tool `name` with `arguments`, starting the process if needed.

  Returns the raw JSON-RPC answer (a `"result"` or an `"error"` message).
  Options: `:timeout_ms` (default #{@call_timeout_ms}); `:on_start`, called
  with the OS pid once the process is ready (to let a job be cancelled by
  `os_pid`). On any `{:error, _}` the process has been discarded.
  """
  @spec call_tool(GenServer.server(), String.t(), map(), keyword()) ::
          {:ok, Protocol.message()} | {:error, error()}
  def call_tool(server \\ __MODULE__, name, arguments, opts \\ []) do
    GenServer.call(server, {:call_tool, name, arguments, opts}, :infinity)
  end

  @doc """
  Stops the process and waits until it is gone (TERM, then KILL by `os_pid`).
  Returns `:ok` when there is nothing to stop, or no writer at all.
  """
  @spec stop(GenServer.server()) :: :ok
  def stop(server \\ __MODULE__) do
    GenServer.call(server, :stop, @stop_timeout_ms)
  catch
    :exit, _reason -> :ok
  end

  @doc "The OS pid of the live process, or `nil`."
  @spec os_pid(GenServer.server()) :: non_neg_integer() | nil
  def os_pid(server \\ __MODULE__), do: GenServer.call(server, :os_pid)

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    {:ok,
     %{
       bin: Keyword.get_lazy(opts, :bin, fn -> Config.bin(:full) end),
       args: Keyword.get(opts, :args, []),
       env: Map.merge(Config.env(), Map.new(Keyword.get(opts, :env, %{}))),
       startup_timeout_ms:
         Keyword.get_lazy(opts, :startup_timeout_ms, &Config.startup_timeout_ms/0),
       worker: nil,
       next_id: 1
     }}
  end

  @impl GenServer
  def handle_call({:call_tool, name, arguments, opts}, _from, state) do
    case ensure_started(state) do
      {:ok, state} -> perform(state, name, arguments, opts)
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:stop, _from, state), do: {:reply, :ok, discard(state)}

  def handle_call(:os_pid, _from, %{worker: nil} = state), do: {:reply, nil, state}
  def handle_call(:os_pid, _from, state), do: {:reply, worker_os_pid(state.worker), state}

  @impl GenServer
  def handle_info({:mcp_worker, pid, {:exited, _phase, _reason}}, %{worker: pid} = state),
    do: {:noreply, %{state | worker: nil}}

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    _ = discard(state)
    :ok
  end

  defp perform(state, name, arguments, opts) do
    notify_start(state.worker, opts)
    request = tool_request(state.next_id, name, arguments)
    timeout = Keyword.get(opts, :timeout_ms, @call_timeout_ms)
    state = %{state | next_id: state.next_id + 1}

    case Worker.call(state.worker, request, timeout_ms: timeout) do
      {:ok, answer} -> {:reply, {:ok, answer}, state}
      {:error, reason} -> {:reply, {:error, reason}, discard(state)}
    end
  end

  defp tool_request(id, name, arguments) do
    %{
      "jsonrpc" => "2.0",
      "id" => id,
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => arguments}
    }
  end

  defp ensure_started(%{worker: pid} = state) when is_pid(pid) do
    if Process.alive?(pid), do: {:ok, state}, else: ensure_started(%{state | worker: nil})
  end

  defp ensure_started(state) do
    opts = [bin: state.bin, args: state.args, env: state.env, owner: self()]

    case Worker.start_link(opts) do
      {:ok, pid} -> await_ready(%{state | worker: pid})
      {:error, reason} -> {:error, {:start_failed, reason}, state}
    end
  end

  # The worker reports its handshake (or its failure) to its owner: this process.
  defp await_ready(%{worker: pid} = state) do
    receive do
      {:mcp_worker, ^pid, :ready} ->
        {:ok, state}

      {:mcp_worker, ^pid, {:exited, _phase, reason}} ->
        {:error, {:start_failed, reason}, %{state | worker: nil}}
    after
      state.startup_timeout_ms + 5_000 ->
        {:error, {:start_failed, :startup_timeout}, discard(state)}
    end
  end

  defp notify_start(worker, opts) do
    case Keyword.get(opts, :on_start) do
      fun when is_function(fun, 1) -> fun.(worker_os_pid(worker))
      _none -> :ok
    end
  end

  defp worker_os_pid(worker) do
    Worker.info(worker).os_pid
  catch
    :exit, _reason -> nil
  end

  defp discard(%{worker: nil} = state), do: state

  defp discard(%{worker: pid} = state) do
    Worker.stop(pid)
    %{state | worker: nil}
  end
end
