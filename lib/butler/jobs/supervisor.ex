defmodule Butler.Jobs.Supervisor do
  @moduledoc """
  Supervises Butler's job engine.

  Strategy `:rest_for_one`: the `Butler.Jobs.Queue` comes first, so anything
  started after it (the serial worker, added in a later phase) restarts when
  the queue restarts. Only started when `config :butler, start_queue: true`
  (dormant until the cutover so that no two writers run during development).
  """

  use Supervisor

  alias Butler.Jobs.Queue

  @doc "Starts the supervisor. Options are passed to `Butler.Jobs.Queue`."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(opts) do
    opts = Keyword.delete(opts, :name)
    Supervisor.init([{Queue, opts}], strategy: :rest_for_one)
  end
end
