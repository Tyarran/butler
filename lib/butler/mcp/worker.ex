defmodule Butler.MCP.Worker do
  @moduledoc """
  One long-lived MCP backend process (`mempalace-mcp` or
  `mempalace-light-mcp`), driven over stdio through an Erlang port.

  This is the **only** module allowed to keep an OS process alive (see
  `AGENTS.md`). It still starts the executable with an argument list, never a
  shell, and kills it by `os_pid` (`Butler.OSProcess`).

  ## Lifecycle

  On start the worker spawns the process and performs the MCP handshake
  itself (`initialize`, then `notifications/initialized`). Once the backend
  answered, the worker is `:ready` and its owner receives

      {:mcp_worker, pid, :ready}

  If the process dies, or the handshake fails or times out, the owner receives

      {:mcp_worker, pid, {:exited, phase, reason}}

  where `phase` is `:starting` or `:ready` and `reason` is
  `{:exit_status, n}`, `:startup_timeout`, `{:handshake_failed, error}` or
  `{:executable_not_found, bin}`, and the worker stops. A worker stopped on
  purpose with `stop/1` sends nothing. A worker whose owner dies stops too.

  ## Multiplexing

  Client requests carry their own ids. The worker rewrites each id to a
  private counter before writing to the backend and restores it on the
  answer, so many requests can be in flight at once on a single process. A
  request has no automatic retry: if the backend dies or is too slow, the
  caller gets an error right away.

  stderr is **not** captured: it goes to the logs of Butler.
  """

  use GenServer, restart: :temporary

  alias Butler.MCP.Config
  alias Butler.MCP.Protocol
  alias Butler.OSProcess

  require Logger

  @client_name "butler-mcp-proxy"
  @handshake_id 0
  @line_chunk_bytes 1_048_576

  @typedoc "Why a worker is not usable any more."
  @type exit_reason ::
          {:exit_status, integer()}
          | :startup_timeout
          | {:handshake_failed, term()}
          | {:executable_not_found, String.t()}

  @type call_error ::
          :not_ready
          | :timeout
          | :worker_unavailable
          | :worker_stopped
          | {:backend_exited, integer()}

  defstruct [
    :owner,
    :bin,
    :port,
    :os_pid,
    :request_timeout,
    :startup_timeout,
    :startup_timer,
    :initialize_result,
    phase: :starting,
    next_id: 1,
    pending: %{},
    buffer: [],
    exited?: false
  ]

  @doc """
  Starts a worker.

  Options:

    * `:bin` (required) - the executable
    * `:args` - argument list (default `[]`)
    * `:env` - extra environment, a map of strings (default `%{}`)
    * `:owner` (required) - process notified of lifecycle events
    * `:request_timeout_ms` / `:startup_timeout_ms` - default to `Butler.MCP.Config`
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  Forwards the JSON-RPC `request` to the backend and waits for its answer.

  The answer keeps the id of `request`.
  """
  @spec call(GenServer.server(), Protocol.message()) ::
          {:ok, Protocol.message()} | {:error, call_error()}
  def call(worker, request) do
    GenServer.call(worker, {:request, request}, :infinity)
  catch
    :exit, _reason -> {:error, :worker_unavailable}
  end

  @doc "Forwards a JSON-RPC notification to the backend (fire and forget)."
  @spec notify(GenServer.server(), Protocol.message()) :: :ok
  def notify(worker, notification), do: GenServer.cast(worker, {:notify, notification})

  @doc "Current phase, OS pid and number of requests in flight."
  @spec info(GenServer.server()) :: %{
          phase: :starting | :ready,
          os_pid: non_neg_integer() | nil,
          pending: non_neg_integer()
        }
  def info(worker), do: GenServer.call(worker, :info)

  @doc "The `result` of the `initialize` answer the backend gave at start-up."
  @spec initialize_result(GenServer.server()) :: {:ok, map()} | :error
  def initialize_result(worker), do: GenServer.call(worker, :initialize_result)

  @doc "Stops the worker and kills its OS process. Sends no event to the owner."
  @spec stop(GenServer.server()) :: :ok
  def stop(worker) do
    GenServer.stop(worker, :normal)
  catch
    :exit, _reason -> :ok
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    owner = Keyword.fetch!(opts, :owner)
    Process.monitor(owner)

    state = %__MODULE__{
      owner: owner,
      bin: Keyword.fetch!(opts, :bin),
      request_timeout: Keyword.get_lazy(opts, :request_timeout_ms, &Config.request_timeout_ms/0),
      startup_timeout: Keyword.get_lazy(opts, :startup_timeout_ms, &Config.startup_timeout_ms/0)
    }

    {:ok, state, {:continue, {:boot, Keyword.get(opts, :args, []), Keyword.get(opts, :env, %{})}}}
  end

  @impl GenServer
  def handle_continue({:boot, args, env}, state) do
    case OSProcess.find_executable(state.bin) do
      {:ok, executable} ->
        {:noreply, spawn_backend(state, executable, args, env)}

      {:error, reason} ->
        fail(%{state | exited?: true}, reason)
    end
  end

  @impl GenServer
  def handle_call({:request, request}, from, %{phase: :ready} = state) do
    internal_id = state.next_id
    write(state, Protocol.with_id(request, internal_id))
    timer = Process.send_after(self(), {:request_timeout, internal_id}, state.request_timeout)
    pending = Map.put(state.pending, internal_id, {from, Map.get(request, "id"), timer})
    {:noreply, %{state | next_id: internal_id + 1, pending: pending}}
  end

  def handle_call({:request, _request}, _from, state), do: {:reply, {:error, :not_ready}, state}

  def handle_call(:info, _from, state) do
    info = %{phase: state.phase, os_pid: state.os_pid, pending: map_size(state.pending)}
    {:reply, info, state}
  end

  def handle_call(:initialize_result, _from, state) do
    reply = if state.initialize_result, do: {:ok, state.initialize_result}, else: :error
    {:reply, reply, state}
  end

  @impl GenServer
  def handle_cast({:notify, notification}, %{phase: :ready} = state) do
    write(state, notification)
    {:noreply, state}
  end

  def handle_cast({:notify, _notification}, state), do: {:noreply, state}

  @impl GenServer
  def handle_info({port, {:data, {:noeol, chunk}}}, %{port: port} = state) do
    {:noreply, %{state | buffer: [state.buffer, chunk]}}
  end

  def handle_info({port, {:data, {:eol, chunk}}}, %{port: port} = state) do
    line = IO.iodata_to_binary([state.buffer, chunk])
    handle_line(line, %{state | buffer: []})
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = %{state | exited?: true}
    fail_pending(state, {:error, {:backend_exited, status}})
    fail(%{state | pending: %{}}, {:exit_status, status})
  end

  def handle_info(:startup_timeout, %{phase: :starting} = state) do
    fail(state, :startup_timeout)
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {{from, _client_id, _timer}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}

      {nil, _pending} ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, _ref, :process, owner, _reason}, %{owner: owner} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, state) do
    fail_pending(state, {:error, :worker_stopped})
    kill(state)
  end

  defp spawn_backend(state, executable, args, env) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :hide,
        {:line, @line_chunk_bytes},
        {:args, args},
        {:env, Enum.map(env, fn {key, value} -> {~c"#{key}", ~c"#{value}"} end)}
      ])

    state = %{
      state
      | port: port,
        os_pid: OSProcess.os_pid(port),
        startup_timer: Process.send_after(self(), :startup_timeout, state.startup_timeout)
    }

    write(state, Protocol.initialize_request(@handshake_id, @client_name))
    state
  end

  defp handle_line(line, state) do
    case Protocol.decode_line(line) do
      {:ok, message} ->
        handle_message(message, state)

      :error ->
        Logger.debug("MCP backend wrote a non-JSON line (#{byte_size(line)} bytes), ignored")
        {:noreply, state}
    end
  end

  defp handle_message(message, state) do
    case Protocol.classify(message) do
      {:response, @handshake_id} -> handshake_answer(message, state)
      {:response, id} -> answer(id, message, state)
      _other -> {:noreply, state}
    end
  end

  defp handshake_answer(%{"result" => result}, %{phase: :starting} = state) do
    Process.cancel_timer(state.startup_timer)
    write(state, Protocol.initialized_notification())
    send(state.owner, {:mcp_worker, self(), :ready})
    {:noreply, %{state | phase: :ready, initialize_result: result, startup_timer: nil}}
  end

  defp handshake_answer(%{"error" => error}, %{phase: :starting} = state) do
    fail(state, {:handshake_failed, error})
  end

  defp handshake_answer(_message, state), do: {:noreply, state}

  defp answer(id, message, state) do
    case Map.pop(state.pending, id) do
      {{from, client_id, timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, {:ok, Protocol.with_id(message, client_id)})
        {:noreply, %{state | pending: pending}}

      {nil, _pending} ->
        # Late answer to a request that already timed out.
        {:noreply, state}
    end
  end

  defp fail(state, reason) do
    send(state.owner, {:mcp_worker, self(), {:exited, state.phase, reason}})
    {:stop, :normal, state}
  end

  defp fail_pending(state, reply) do
    Enum.each(state.pending, fn {_id, {from, _client_id, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, reply)
    end)
  end

  defp write(%{port: port}, message) do
    Port.command(port, Protocol.encode_line(message))
  end

  defp kill(%{exited?: true}), do: :ok
  defp kill(%{port: nil}), do: :ok

  defp kill(%{port: port, os_pid: os_pid}) do
    OSProcess.signal(os_pid, "TERM")

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      OSProcess.term_grace_ms() ->
        OSProcess.signal(os_pid, "KILL")
        OSProcess.close(port)
    end

    :ok
  end
end
