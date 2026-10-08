defmodule Butler.MCP.BackendSupervisor do
  @moduledoc """
  Supervises one backend: its dynamic supervisor of workers, then the
  `Butler.MCP.Backend` state machine.

  Strategy `:rest_for_one`: if the dynamic supervisor dies, the backend is
  restarted with it. If only the backend dies, running workers notice that
  their owner is gone and stop on their own.

  Having one such supervisor per backend keeps a crash of `:full` from ever
  reaching `:light`.
  """

  use Supervisor

  alias Butler.MCP.Backend
  alias Butler.MCP.Config

  @doc "Starts the supervisor of `backend`."
  @spec start_link(Config.backend()) :: Supervisor.on_start()
  def start_link(backend) when backend in [:full, :light] do
    Supervisor.start_link(__MODULE__, backend)
  end

  @doc "Registered name of the `Butler.MCP.Backend` of `backend`."
  @spec backend_name(Config.backend()) :: atom()
  def backend_name(:full), do: Butler.MCP.Backend.Full
  def backend_name(:light), do: Butler.MCP.Backend.Light

  @doc "Registered name of the worker supervisor of `backend`."
  @spec workers_name(Config.backend()) :: atom()
  def workers_name(:full), do: Butler.MCP.Workers.Full
  def workers_name(:light), do: Butler.MCP.Workers.Light

  @impl Supervisor
  def init(backend) do
    children = [
      {DynamicSupervisor, strategy: :one_for_one, name: workers_name(backend)},
      {Backend,
       id: backend, name: backend_name(backend), worker_supervisor: workers_name(backend)}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
