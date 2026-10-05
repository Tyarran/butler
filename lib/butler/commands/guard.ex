defmodule Butler.Commands.Guard do
  @moduledoc """
  Decides whether a direct (daemon-less) command may run.

  Direct commands (`repair`, `compress`, `migrate-wings`) need the daemon
  stopped, and stopping it interrupts running jobs. They are therefore refused
  while jobs in a *blocking state* exist. The states come from
  `config :butler, :blocking_job_states` (default `[:queued, :running]`);
  `blocking?/1` is the single predicate used everywhere.
  """

  alias Butler.Daemon.Status
  alias Butler.Jobs.Job
  alias Butler.Jobs.Store

  @default_blocking_states [:queued, :running]

  @doc "The job states that block direct commands."
  @spec blocking_states() :: [Job.state()]
  def blocking_states,
    do: Application.get_env(:butler, :blocking_job_states, @default_blocking_states)

  @doc "Whether this job blocks direct commands."
  @spec blocking?(Job.t()) :: boolean()
  def blocking?(%Job{state: state}), do: state in blocking_states()

  @doc """
  Checks the queue.

  Returns `:ok` when no job blocks (or when there is no queue database at
  all), `{:blocked, jobs}` with the blocking jobs otherwise, and
  `{:error, reason}` when the queue exists but cannot be read: in doubt, the
  caller must refuse.
  """
  @spec check(Path.t() | nil) :: :ok | {:blocked, [Job.t(), ...]} | {:error, term()}
  def check(queue_path \\ nil)

  def check(nil) do
    case Status.resolve().queue_path do
      nil -> :ok
      queue_path -> check(queue_path)
    end
  end

  def check(queue_path) do
    case Store.list(queue_path, limit: 1_000) do
      {:ok, jobs} -> jobs |> Enum.filter(&blocking?/1) |> verdict()
      {:error, :not_found} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp verdict([]), do: :ok
  defp verdict(jobs), do: {:blocked, jobs}
end
