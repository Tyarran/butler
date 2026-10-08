defmodule Butler.MCP.Supervisor do
  @moduledoc """
  Root of the MCP proxy subsystem.

  It does not depend on `ButlerWeb`: the web layer only calls `Butler.MCP`.
  It holds the client sessions and one `Butler.MCP.BackendSupervisor` per
  backend, so that a crash in one backend never takes the other down.
  """

  use Supervisor

  alias Butler.MCP.BackendSupervisor
  alias Butler.MCP.Config
  alias Butler.MCP.Sessions

  @doc "Starts the subsystem."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl Supervisor
  def init(_opts) do
    backends =
      for backend <- Config.backends() do
        Supervisor.child_spec({BackendSupervisor, backend}, id: {BackendSupervisor, backend})
      end

    Supervisor.init([Sessions | backends], strategy: :one_for_one)
  end
end
