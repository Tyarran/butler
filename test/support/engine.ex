defmodule Butler.Test.Engine do
  @moduledoc """
  Starts Butler's job engine for a test, in a throwaway state dir.

  The application does not start the engine in the test environment
  (`start_jobs: false`). `start_queue!/1` points `:state_dir` at the test's
  tmp dir (restored on exit) and starts the default-named
  `Butler.Jobs.Queue`; `start_worker!/1` starts the default-named
  `Butler.Jobs.Worker`. Tests using it must be `async: false` (global names,
  application env). All data is synthetic.
  """

  import ExUnit.Callbacks, only: [on_exit: 1, start_supervised!: 1]

  alias Butler.Jobs.Queue
  alias Butler.Jobs.Worker

  @doc "Starts the queue in `<tmp>/state`; returns the queue database path."
  @spec start_queue!(Path.t()) :: Path.t()
  def start_queue!(tmp) do
    previous = Application.fetch_env(:butler, :state_dir)
    state_dir = Path.join(tmp, "state")
    Application.put_env(:butler, :state_dir, state_dir)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:butler, :state_dir, value)
        :error -> Application.delete_env(:butler, :state_dir)
      end
    end)

    path = Path.join(state_dir, "queue.sqlite3")
    start_supervised!({Queue, name: Queue, path: path})
    path
  end

  @doc """
  Starts the worker. By default the legacy guard says the Python daemon is
  alive, so the worker stays `:blocked` and never claims (nor runs) a job;
  pass `legacy_running?: fn -> false end` and a CLI mock to let it work.
  """
  @spec start_worker!(keyword()) :: pid()
  def start_worker!(opts \\ []) do
    defaults = [name: Worker, legacy_running?: fn -> true end]
    start_supervised!({Worker, Keyword.merge(defaults, opts)})
    Process.whereis(Worker)
  end
end
