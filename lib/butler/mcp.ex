defmodule Butler.MCP do
  @moduledoc """
  Facade of the MCP proxy: the only module the web layer talks to.

  The proxy relays MCP messages (JSON-RPC 2.0, "Streamable HTTP" transport,
  one JSON response per request, no SSE) to long-lived `mempalace-mcp` /
  `mempalace-light-mcp` processes, so that many agent sessions share them.

  Client sessions (`Mcp-Session-Id`) are owned by Butler. The `initialize`
  answer comes from the handshake the backend workers already did, so a
  session never depends on a particular Python process: processes may be
  rotated or replaced under it.

  Notifications and responses sent by clients are acknowledged and dropped.
  """

  alias Butler.MCP.Backend
  alias Butler.MCP.BackendSupervisor
  alias Butler.MCP.Config
  alias Butler.MCP.Demo
  alias Butler.MCP.Protocol
  alias Butler.MCP.Sessions
  alias Butler.MCP.Worker

  @typedoc "What to answer over HTTP."
  @type result ::
          {:json, Protocol.message()}
          | {:json, Protocol.message(), session_id :: String.t()}
          | :accepted
          | {:bad_request, Protocol.message()}
          | :unknown_session
          | :unavailable

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

  @doc "Forces the rotation of `backend` (see `Butler.MCP.Backend.restart/1`)."
  @spec restart(Config.backend()) :: :ok | {:error, :unavailable}
  def restart(backend) do
    cond do
      not Config.backend?(backend) -> {:error, :unavailable}
      running?() -> backend |> BackendSupervisor.backend_name() |> Backend.restart()
      Config.demo?() -> :ok
      true -> {:error, :unavailable}
    end
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

  defp dispatch(backend, _session_id, {:request, id, "initialize", _params}, _body) do
    initialize(backend, id)
  end

  defp dispatch(backend, session_id, {:request, id, _method, _params}, body) do
    with_session(backend, session_id, id, fn -> forward(backend, id, body) end)
  end

  defp dispatch(backend, session_id, _notification_or_response, _body) do
    with_session(backend, session_id, nil, fn -> :accepted end)
  end

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
