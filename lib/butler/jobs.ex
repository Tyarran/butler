defmodule Butler.Jobs do
  @moduledoc """
  The dashboard's door to Butler's job engine.

  Thin functions over `Butler.Jobs.Queue` and `Butler.Jobs.Worker` (both named
  processes started by `Butler.Jobs.Supervisor`): LiveViews call this module
  and never touch SQLite, the CLI or the worker's internals. Every function
  answers with a tuple and never raises or exits when the engine is down
  (`{:error, {:queue_unavailable, reason}}` / `{:error, :worker_unavailable}`).

  Submissions are validated with `Butler.Jobs.Kinds.validate_payload/2`, the
  very rules the worker applies when it runs the job.
  """

  alias Butler.Jobs.Job
  alias Butler.Jobs.Kinds
  alias Butler.Jobs.Queue
  alias Butler.Jobs.Worker

  @list_limit 200

  @type enqueue_error ::
          :unknown_kind
          | {:invalid, String.t() | nil, String.t()}
          | {:queue_unavailable, term()}
          | term()

  @doc """
  Validates `payload` for `kind` and enqueues it.

  Options: `:priority` (default 0) and `:dedupe_key`. Returns the job and
  whether it was `:created` or `:deduplicated`.
  """
  @spec enqueue(String.t(), map(), keyword()) ::
          {:ok, Job.t(), :created | :deduplicated} | {:error, enqueue_error()}
  def enqueue(kind, payload, opts \\ []) do
    with {:ok, payload} <- Kinds.validate_payload(kind, payload) do
      attrs = %{
        kind: kind,
        payload: payload,
        priority: Keyword.get(opts, :priority, 0),
        dedupe_key: Keyword.get(opts, :dedupe_key)
      }

      Queue.enqueue(Queue, attrs)
    end
  end

  @doc "Fetches a job."
  @spec get(String.t()) :: {:ok, Job.t()} | {:error, :job_not_found | term()}
  def get(id), do: Queue.get(Queue, id)

  @doc "Lists jobs (see `Butler.Jobs.Store.list/2`); limit defaults to #{@list_limit}."
  @spec list(keyword()) :: {:ok, [Job.t()]} | {:error, term()}
  def list(opts \\ []), do: Queue.list(Queue, Keyword.put_new(opts, :limit, @list_limit))

  @doc "Number of jobs per state."
  @spec counts() :: {:ok, %{Job.state() => non_neg_integer()}} | {:error, term()}
  def counts, do: Queue.counts(Queue)

  @doc "Kinds present in the queue."
  @spec kinds() :: {:ok, [String.t()]} | {:error, term()}
  def kinds, do: Queue.kinds(Queue)

  @doc """
  Cancels a job: a queued job at once, the running one by stopping its
  process (it is finished as `cancelled` shortly after).
  """
  @spec cancel(String.t()) :: {:ok, Job.t()} | {:error, term()}
  def cancel(id) do
    Worker.cancel(id)
  catch
    :exit, _reason -> {:error, :worker_unavailable}
  end

  @doc "Enqueues a new job with the kind and payload of a finished one."
  @spec retry(Job.t()) :: {:ok, Job.t(), :created | :deduplicated} | {:error, enqueue_error()}
  def retry(%Job{kind: kind, payload: %{} = payload}) when is_binary(kind),
    do: enqueue(kind, payload)

  def retry(%Job{}), do: {:error, :not_retryable}

  @doc "Whether a job can be retried from the dashboard (failed or cancelled)."
  @spec retryable?(Job.t()) :: boolean()
  def retryable?(%Job{state: state, payload: %{}}), do: state in [:failed, :cancelled]
  def retryable?(%Job{}), do: false

  @doc "Whether the job can be cancelled (queued or running)."
  @spec cancellable?(Job.t()) :: boolean()
  def cancellable?(%Job{} = job), do: Job.active?(job)

  @doc "The worker's status and active job id, or `:unavailable` when it is not running."
  @spec worker_status() :: %{
          status: Worker.status() | :unavailable,
          active_job_id: String.t() | nil
        }
  def worker_status do
    Worker.status()
  catch
    :exit, _reason -> %{status: :unavailable, active_job_id: nil}
  end

  @doc """
  Queue positions of the queued jobs, as a map of job id to position.

  Position 1 is the job the worker claims next (`priority DESC, created_at
  ASC`). The running job is not counted.
  """
  @spec positions() :: %{String.t() => pos_integer()}
  def positions do
    case Queue.list(Queue, state: :queued, limit: 1_000) do
      {:ok, jobs} -> position_map(jobs)
      {:error, _reason} -> %{}
    end
  end

  @doc "Same as `positions/0` for an already loaded list of queued jobs."
  @spec position_map([Job.t()]) :: %{String.t() => pos_integer()}
  def position_map(jobs) do
    jobs
    |> Enum.filter(&(&1.state == :queued))
    # `list/1` is newest first: reverse so that ties keep insertion order.
    |> Enum.reverse()
    |> Enum.sort_by(&{-&1.priority, created_micros(&1)})
    |> Enum.with_index(1)
    |> Map.new(fn {job, position} -> {job.id, position} end)
  end

  defp created_micros(%Job{created_at: %DateTime{} = at}), do: DateTime.to_unix(at, :microsecond)
  defp created_micros(%Job{}), do: 0
end
