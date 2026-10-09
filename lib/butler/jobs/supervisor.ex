defmodule Butler.Jobs.Supervisor do
  @moduledoc """
  Supervises Butler's job engine.

  Strategy `:rest_for_one`: the `Butler.Jobs.Queue` comes first, so the
  `Butler.Jobs.Worker` started after it restarts when the queue restarts. The
  worker has a 20 s shutdown budget (kill the child, settle the job). It is
  always started by `Butler.Application`, except in the test environment
  (`config :butler, start_jobs: false`: tests start their own engine in a
  throwaway state dir). The worker itself stays `:blocked` while the legacy
  Python daemon is alive, so that two writers never share a palace.
  """

  use Supervisor

  alias Butler.Jobs.Queue
  alias Butler.Jobs.Worker

  @doc """
  Starts the supervisor. Options are passed to `Butler.Jobs.Queue`, except
  `:worker`, the keyword list given to `Butler.Jobs.Worker`.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl Supervisor
  def init(opts) do
    {worker_opts, opts} = opts |> Keyword.delete(:name) |> Keyword.pop(:worker, [])
    Supervisor.init([{Queue, opts}, {Worker, worker_opts}], strategy: :rest_for_one)
  end
end
