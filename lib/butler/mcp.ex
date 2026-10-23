defmodule Butler.MCP do
  @moduledoc """
  Facade of the MCP proxy: the only module the web layer talks to.

  The proxy relays MCP messages (JSON-RPC 2.0, "Streamable HTTP" transport,
  one JSON response per request, no SSE) to pools of long-lived
  `mempalace-mcp` / `mempalace-light-mcp` processes (round-robin), so that
  many agent sessions share them.

  Client sessions (`Mcp-Session-Id`) are owned by Butler. The `initialize`
  answer comes from the handshake the backend workers already did, so a
  session never depends on a particular Python process: processes may be
  rotated or replaced under it.

  Notifications and responses sent by clients are acknowledged and dropped.

  While `Butler.Maintenance` is active, every request is refused at once with
  the JSON-RPC error -32001 (no worker is checked out). `tools/call` only
  forwards the read tools of `Butler.MCP.Tools`; write, maintenance and
  unknown tools are refused: writes go through the Butler API.
  """

  alias Butler.Maintenance
  alias Butler.MCP.Backend
  alias Butler.MCP.BackendSupervisor
  alias Butler.MCP.Config
  alias Butler.MCP.Demo
  alias Butler.MCP.Protocol
  alias Butler.MCP.Sessions
  alias Butler.MCP.Tools
  alias Butler.MCP.Worker

  @typedoc "What to answer over HTTP."
  @type result ::
          {:json, Protocol.message()}
          | {:json, Protocol.message(), session_id :: String.t()}
          | :accepted
          | {:bad_request, Protocol.message()}
          | :unknown_session
          | :unavailable

  @maintenance_code -32_001
  @maintenance_message "Maintenance in progress, retry later"
  @invalid_params -32_602
  @write_refused "write tools must be submitted through the Butler API"

  @type backend_status :: %{
          required(:sessions) => non_neg_integer(),
          optional(atom()) => term()
        }

  @doc "Whether the proxy subsystem is running."
  @spec running?() :: boolean()
  def running?, do: Process.whereis(Butler.MCP.Supervisor) != nil

  @doc """
  Handles one decoded HTTP body for `backend`.

  `session_id` is the value of the `Mcp-Session-Id` header, if any.
  """
  @spec handle(Config.backend(), String.t() | nil, term()) :: result()
  def handle(backend, session_id, body) do
    if running?(),
      do: dispatch(backend, session_id, Protocol.classify(body), body),
      else: :unavailable
  end

  @doc "Ends a client session."
  @spec close_session(Config.backend(), String.t() | nil) :: :ok | :unknown_session
  def close_session(backend, session_id) do
    if Sessions.validate(session_id, backend) == :ok do
      Sessions.delete(session_id)
    else
      :unknown_session
    end
  end

  @doc "Snapshots of the backends, with their number of client sessions."
  @spec status() :: [backend_status()]
  def status do
    cond do
      running?() -> live_status()
      Config.demo?() -> Demo.status()
      true -> []
    end
  end

  defp live_status do
    for backend <- Config.backends() do
      backend
      |> BackendSupervisor.backend_name()
      |> Backend.status()
      |> Map.put(:sessions, Sessions.count(backend))
    end
  end

  @doc "Replaces every process of `backend` now (see `Butler.MCP.Backend.restart/1`)."
  @spec restart(Config.backend()) :: :ok | {:error, :unavailable}
  def restart(backend) do
    cond do
      not Config.backend?(backend) -> {:error, :unavailable}
      running?() -> backend |> BackendSupervisor.backend_name() |> Backend.restart()
      Config.demo?() -> :ok
      true -> {:error, :unavailable}
    end
  end

  @doc """
  Maintenance: waits (at most `timeout` ms) for the requests in flight to
  end. `:timeout` when some are still pending (the caller goes on and
  `suspend/0` cuts them).
  """
  @spec drain(non_neg_integer()) :: :ok | :timeout
  def drain(timeout) do
    if running?() do
      deadline = System.monotonic_time(:millisecond) + timeout

      results =
        for backend <- Config.backends() do
          remaining = max(deadline - System.monotonic_time(:millisecond), 0)
          drain_backend(backend, remaining)
        end

      if :timeout in results, do: :timeout, else: :ok
    else
      :ok
    end
  end

  # A backend that is restarting (or does not answer) counts as not drained.
  defp drain_backend(backend, remaining) do
    backend |> BackendSupervisor.backend_name() |> Backend.drain(remaining)
  catch
    :exit, _reason -> :timeout
  end

  @doc """
  Maintenance: stops every proxy worker (and their OS processes) and starts
  none until `resume/0`. `:ok` when the proxy is not running. When a backend
  cannot be suspended (timeout, restart) the result is `{:error, reason}`:
  proxy processes may still be alive, so the caller must not start the CLI.
  """
  @spec suspend() :: :ok | {:error, term()}
  def suspend, do: each_backend(&Backend.suspend/1)

  @doc "Ends the suspension: the backends start fresh workers. Idempotent."
  @spec resume() :: :ok | {:error, term()}
  def resume, do: each_backend(&Backend.resume/1)

  # Every backend is tried, even after a failure; the first failure is returned.
  defp each_backend(fun) do
    if running?() do
      results =
        for backend <- Config.backends() do
          backend |> BackendSupervisor.backend_name() |> call_backend(fun)
        end

      Enum.find(results, :ok, &(&1 != :ok))
    else
      :ok
    end
  end

  defp call_backend(name, fun) do
    fun.(name)
  catch
    :exit, reason -> {:error, {:backend_unavailable, reason}}
  end

  @doc "Subscribes the caller to `{:mcp_changed, backend}` notifications."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Butler.PubSub, Backend.topic())

  defp dispatch(_backend, _session_id, :batch, _body) do
    {:bad_request, Protocol.invalid_request(nil)}
  end

  defp dispatch(_backend, _session_id, :invalid, body) do
    {:bad_request, Protocol.invalid_request(request_id(body))}
  end

  # Maintenance: every request (initialize included) is refused at once,
  # before any session or worker is looked at. Notifications are not gated.
  defp dispatch(backend, session_id, {:request, id, _method, _params} = request, body) do
    if Maintenance.active?() do
      {:json, Protocol.error(id, @maintenance_code, @maintenance_message)}
    else
      route(backend, session_id, request, body)
    end
  end

  defp dispatch(backend, session_id, _notification_or_response, _body) do
    with_session(backend, session_id, nil, fn -> :accepted end)
  end

  defp route(backend, _session_id, {:request, id, "initialize", _params}, _body) do
    initialize(backend, id)
  end

  defp route(backend, session_id, {:request, id, method, params}, body) do
    with_session(backend, session_id, id, fn ->
      if allowed?(method, params),
        do: forward(backend, id, body),
        else: {:json, Protocol.error(id, @invalid_params, @write_refused)}
    end)
  end

  # Only the read tools reach a worker; the name must be a known string.
  defp allowed?("tools/call", params), do: Tools.read?(Map.get(params, "name"))
  defp allowed?(_method, _params), do: true

  defp with_session(_backend, nil, id, _fun) do
    {:bad_request, Protocol.error(id, -32_600, "Mcp-Session-Id header is required")}
  end

  defp with_session(backend, session_id, _id, fun) do
    case Sessions.validate(session_id, backend) do
      :ok -> fun.()
      :error -> :unknown_session
    end
  end

  defp initialize(backend, id) do
    with {:ok, worker} <- checkout(backend),
         {:ok, result} <- Worker.initialize_result(worker) do
      {:json, Protocol.result(id, result), Sessions.create(backend)}
    else
      {:error, reason} -> failure(backend, id, reason)
      :error -> failure(backend, id, :not_ready)
    end
  end

  defp forward(backend, id, body) do
    with {:ok, worker} <- checkout(backend),
         {:ok, response} <- Worker.call(worker, body) do
      {:json, response}
    else
      {:error, reason} -> failure(backend, id, reason)
    end
  end

  defp checkout(backend), do: backend |> BackendSupervisor.backend_name() |> Backend.checkout()

  # Between the end of a maintenance (proxy resumed first, gate left after)
  # and a request that already passed the gate: same answer as the gate.
  defp failure(_backend, id, :suspended),
    do: {:json, Protocol.error(id, @maintenance_code, @maintenance_message)}

  defp failure(backend, id, reason) do
    backend |> BackendSupervisor.backend_name() |> Backend.record_error()
    {:json, Protocol.internal_error(id, describe(reason))}
  end

  defp describe(:timeout), do: "The MemPalace backend did not answer in time"
  defp describe({:backend_exited, status}), do: "The MemPalace backend exited (status #{status})"

  defp describe({:failed, reason}),
    do: "The MemPalace backend failed to start: #{inspect(reason)}"

  defp describe(:unavailable), do: "The MemPalace backend is still starting"
  defp describe(_other), do: "The MemPalace backend is unavailable"

  defp request_id(%{"id" => id}) when is_integer(id) or is_binary(id), do: id
  defp request_id(_body), do: nil
end
