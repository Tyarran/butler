defmodule Butler.Jobs.Orphans do
  @moduledoc """
  Kills `mempalace` processes left behind by a crashed Butler.

  A job claimed by the worker records the OS pid of its process
  (`jobs.os_pid`). When Butler starts and finds a `running` job whose pid is
  still alive **and** whose command line mentions `mempalace`, that process is
  an orphan holding the palace lock: it is terminated (`SIGTERM`, then
  `SIGKILL` after a grace period) before `recover_running` re-queues the job.

  A live pid whose command line does not match is a recycled pid (some other
  program) and is never signalled. Liveness is read from `/proc` only.
  """

  alias Butler.Jobs.Job
  alias Butler.OSProcess

  @poll_ms 25
  @kill_wait_ms 1_000

  @type opt ::
          {:proc_root, Path.t()}
          | {:signal, (non_neg_integer(), String.t() -> any())}
          | {:grace_ms, non_neg_integer()}

  @doc """
  Whether `os_pid` is a live process whose command line contains `mempalace`.
  Option: `:proc_root` (default `/proc`).
  """
  @spec mempalace_process?(non_neg_integer(), [opt()]) :: boolean()
  def mempalace_process?(os_pid, opts \\ []) do
    proc_root = Keyword.get(opts, :proc_root, "/proc")

    case File.read(Path.join([proc_root, Integer.to_string(os_pid), "cmdline"])) do
      {:ok, cmdline} -> String.contains?(cmdline, "mempalace")
      {:error, _reason} -> false
    end
  end

  @doc """
  Terminates the orphans among `jobs` and returns the pids that were signalled.

  Options: `:proc_root` (default `/proc`), `:signal` (default
  `Butler.OSProcess.signal/2`), `:grace_ms` (default
  `Butler.OSProcess.term_grace_ms/0`).
  """
  @spec reap([Job.t()], [opt()]) :: [non_neg_integer()]
  def reap(jobs, opts \\ []) do
    jobs
    |> Enum.map(& &1.os_pid)
    |> Enum.filter(&is_integer/1)
    |> Enum.uniq()
    |> Enum.filter(&mempalace_process?(&1, opts))
    |> Enum.map(&terminate(&1, opts))
  end

  defp terminate(os_pid, opts) do
    signal = Keyword.get(opts, :signal, &OSProcess.signal/2)
    grace = Keyword.get(opts, :grace_ms, OSProcess.term_grace_ms())

    signal.(os_pid, "TERM")

    unless wait_gone(os_pid, opts, grace) do
      signal.(os_pid, "KILL")
      wait_gone(os_pid, opts, @kill_wait_ms)
    end

    os_pid
  end

  defp wait_gone(os_pid, opts, budget_ms) do
    cond do
      not mempalace_process?(os_pid, opts) ->
        true

      budget_ms <= 0 ->
        false

      true ->
        Process.sleep(@poll_ms)
        wait_gone(os_pid, opts, budget_ms - @poll_ms)
    end
  end
end
