defmodule Butler.Daemon.Status do
  @moduledoc """
  Resolves whether the MemPalace daemon is running, without calling it.

  The daemon is considered **running** iff the PID recorded in its
  `endpoint.json` is alive (checked through `/proc/<pid>`) and its queue
  database exists. Anything else — no endpoint, stale endpoint, dead PID —
  is **stopped**. Even when stopped, the queue is read so that counters and
  history remain available.

  > #### Linux only {: .warning}
  > Liveness relies on `/proc`. On other platforms the daemon is always
  > reported as stopped. A recycled PID could yield a false "running" until
  > the daemon's own cleanup removes the stale endpoint.
  """

  alias Butler.Daemon.Locator
  alias Butler.Jobs.Store
  alias Butler.Palace

  @proc_root "/proc"

  defstruct [:state, :pid, :palace_path, :started_at, :queue_path, :counts]

  @type t :: %__MODULE__{
          state: :running | :stopped,
          pid: non_neg_integer() | nil,
          palace_path: Path.t(),
          started_at: DateTime.t() | nil,
          queue_path: Path.t() | nil,
          counts: %{atom() => non_neg_integer()} | nil
        }

  @type opt ::
          {:root, Path.t()}
          | {:palace_path, Path.t()}
          | {:proc_root, Path.t()}

  @doc """
  Resolves the daemon status.

  Options (mainly for tests): `:root` (daemon state root), `:palace_path` and
  `:proc_root` (defaults to `#{@proc_root}`).
  """
  @spec resolve([opt()]) :: t()
  def resolve(opts \\ []) do
    root = Keyword.get_lazy(opts, :root, &Palace.daemon_root/0)
    palace = Keyword.get_lazy(opts, :palace_path, &Palace.path/0)
    proc_root = Keyword.get(opts, :proc_root, @proc_root)

    case Locator.find(root, palace) do
      {:ok, found} -> from_location(found, proc_root)
      {:error, :not_found} -> %__MODULE__{state: :stopped, palace_path: palace}
    end
  end

  @doc "Whether a process with this PID exists (via `/proc`, or the given root)."
  @spec pid_alive?(non_neg_integer() | nil, Path.t()) :: boolean()
  def pid_alive?(pid, proc_root \\ @proc_root)

  def pid_alive?(pid, proc_root) when is_integer(pid),
    do: File.dir?(Path.join(proc_root, "#{pid}"))

  def pid_alive?(_pid, _proc_root), do: false

  defp from_location(found, proc_root) do
    queue? = File.regular?(found.queue_path)
    running? = queue? and pid_alive?(found.pid, proc_root)

    %__MODULE__{
      state: if(running?, do: :running, else: :stopped),
      pid: found.pid,
      palace_path: found.palace_path,
      started_at: found.started_at,
      queue_path: if(queue?, do: found.queue_path),
      counts: counts(found.queue_path)
    }
  end

  defp counts(queue_path) do
    case Store.counts(queue_path) do
      {:ok, counts} -> counts
      {:error, _reason} -> nil
    end
  end
end
