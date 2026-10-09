defmodule Butler.Jobs.Queue do
  @moduledoc """
  GenServer owning the connection to Butler's own queue database.

  Every operation of `Butler.Jobs.Store` is serialized through this process.
  State changes are broadcast on `Butler.PubSub`, topic `topic/0`
  (`"butler:queue"`), as `{:job_changed, %Butler.Jobs.Job{}}`.

  At startup (and then daily) terminal jobs older than the retention period
  (`BUTLER_RETENTION_DAYS`, default 7 days) are pruned.
  """

  use GenServer

  alias Butler.Jobs.Job
  alias Butler.Jobs.Store
  alias Butler.Paths

  @topic "butler:queue"
  @default_retention_days 7
  @prune_interval_ms 86_400_000
  @call_timeout 15_000

  @type server :: GenServer.server()

  @doc "Starts the queue. Options: `:name` (default `#{inspect(__MODULE__)}`), `:path`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "PubSub topic of job changes."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "Subscribes the calling process to `{:job_changed, job}` messages."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Butler.PubSub, @topic)

  @doc "Retention in days for terminal jobs (`BUTLER_RETENTION_DAYS`, invalid falls back to 7)."
  @spec retention_days() :: pos_integer()
  def retention_days do
    with value when is_binary(value) <- System.get_env("BUTLER_RETENTION_DAYS"),
         {days, ""} when days > 0 <- Integer.parse(value) do
      days
    else
      _ -> @default_retention_days
    end
  end

  @doc "See `Butler.Jobs.Store.enqueue/3`. Broadcasts when a job was created."
  @spec enqueue(server(), map(), keyword()) ::
          {:ok, Job.t(), :created | :deduplicated} | {:error, term()}
  def enqueue(server, attrs, opts \\ []), do: call(server, {:enqueue, attrs, opts})

  @doc "See `Butler.Jobs.Store.claim_next/3`. Broadcasts the claimed job."
  @spec claim_next(server(), [String.t()], keyword()) :: {:ok, Job.t() | nil} | {:error, term()}
  def claim_next(server, exclude_ids \\ [], opts \\ []),
    do: call(server, {:claim_next, exclude_ids, opts})

  @doc "See `Butler.Jobs.Store.set_os_pid/3`."
  @spec set_os_pid(server(), String.t(), non_neg_integer()) ::
          {:ok, Job.t()} | {:error, term()}
  def set_os_pid(server, id, os_pid), do: call(server, {:set_os_pid, id, os_pid})

  @doc "See `Butler.Jobs.Store.finish/5`. Broadcasts the finished job."
  @spec finish(server(), String.t(), :succeeded | :failed | :cancelled, map(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def finish(server, id, state, attrs \\ %{}, opts \\ []),
    do: call(server, {:finish, id, state, attrs, opts})

  @doc "See `Butler.Jobs.Store.defer/4`. Broadcasts the re-queued job."
  @spec defer(server(), String.t(), DateTime.t() | String.t(), term()) ::
          {:ok, Job.t()} | {:error, term()}
  def defer(server, id, claimed_started_at, error),
    do: call(server, {:defer, id, claimed_started_at, error})

  @doc "See `Butler.Jobs.Store.cancel/3`. Broadcasts when a queued job was cancelled."
  @spec cancel(server(), String.t(), keyword()) :: {:ok, Job.t()} | {:error, term()}
  def cancel(server, id, opts \\ []), do: call(server, {:cancel, id, opts})

  @doc "See `Butler.Jobs.Store.recover_running/3`."
  @spec recover_running(server(), [String.t()], keyword()) ::
          {:ok, %{requeued: non_neg_integer(), failed: non_neg_integer()}} | {:error, term()}
  def recover_running(server, idempotent_kinds, opts \\ []),
    do: call(server, {:recover_running, idempotent_kinds, opts})

  @doc "See `Butler.Jobs.Store.prune_terminal/3`."
  @spec prune_terminal(server(), pos_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def prune_terminal(server, days, opts \\ []), do: call(server, {:prune_terminal, days, opts})

  @doc "See `Butler.Jobs.Store.get/2`."
  @spec get(server(), String.t()) :: {:ok, Job.t()} | {:error, :job_not_found | term()}
  def get(server, id), do: call(server, {:get, id})

  @doc "See `Butler.Jobs.Store.list/2`."
  @spec list(server(), keyword()) :: {:ok, [Job.t()]} | {:error, term()}
  def list(server, opts \\ []), do: call(server, {:list, opts})

  @doc "See `Butler.Jobs.Store.counts/1`."
  @spec counts(server()) :: {:ok, %{Job.state() => non_neg_integer()}} | {:error, term()}
  def counts(server), do: call(server, :counts)

  @doc "See `Butler.Jobs.Store.kinds/1`."
  @spec kinds(server()) :: {:ok, [String.t()]} | {:error, term()}
  def kinds(server), do: call(server, :kinds)

  defp call(server, message) do
    GenServer.call(server, message, @call_timeout)
  catch
    :exit, {reason, _call} -> {:error, {:queue_unavailable, reason}}
  end

  # -- Server ------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    # Trap exits so that `terminate/2` closes the database on shutdown.
    Process.flag(:trap_exit, true)
    path = Keyword.get_lazy(opts, :path, &Paths.queue_path/0)

    case Store.open(path) do
      {:ok, db} -> {:ok, %{db: db, path: path}, {:continue, :prune}}
      {:error, reason} -> {:stop, {:queue_open_failed, reason}}
    end
  end

  @impl GenServer
  def handle_continue(:prune, state), do: {:noreply, prune(state)}

  @impl GenServer
  def handle_info(:prune, state), do: {:noreply, prune(state)}
  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  def terminate(_reason, %{db: db}) do
    Store.close(db)
    :ok
  end

  defp prune(%{db: db} = state) do
    Store.prune_terminal(db, retention_days())
    Process.send_after(self(), :prune, @prune_interval_ms)
    state
  end

  @impl GenServer
  def handle_call({:enqueue, attrs, opts}, _from, %{db: db} = state) do
    result = Store.enqueue(db, attrs, opts)

    case result do
      {:ok, job, :created} -> broadcast(job)
      _ -> :ok
    end

    {:reply, result, state}
  end

  def handle_call({:claim_next, exclude, opts}, _from, %{db: db} = state),
    do: {:reply, db |> Store.claim_next(exclude, opts) |> broadcasting(), state}

  def handle_call({:set_os_pid, id, os_pid}, _from, %{db: db} = state),
    do: {:reply, Store.set_os_pid(db, id, os_pid), state}

  def handle_call({:finish, id, job_state, attrs, opts}, _from, %{db: db} = state),
    do: {:reply, db |> Store.finish(id, job_state, attrs, opts) |> broadcasting(), state}

  def handle_call({:defer, id, started_at, error}, _from, %{db: db} = state),
    do: {:reply, db |> Store.defer(id, started_at, error) |> broadcasting(), state}

  def handle_call({:cancel, id, opts}, _from, %{db: db} = state) do
    result = Store.cancel(db, id, opts)

    case result do
      {:ok, %Job{state: :cancelled} = job} -> broadcast(job)
      _ -> :ok
    end

    {:reply, result, state}
  end

  def handle_call({:recover_running, kinds, opts}, _from, %{db: db} = state),
    do: {:reply, Store.recover_running(db, kinds, opts), state}

  def handle_call({:prune_terminal, days, opts}, _from, %{db: db} = state),
    do: {:reply, Store.prune_terminal(db, days, opts), state}

  def handle_call({:get, id}, _from, %{db: db} = state), do: {:reply, Store.get(db, id), state}

  def handle_call({:list, opts}, _from, %{db: db} = state),
    do: {:reply, Store.list(db, opts), state}

  def handle_call(:counts, _from, %{db: db} = state), do: {:reply, Store.counts(db), state}
  def handle_call(:kinds, _from, %{db: db} = state), do: {:reply, Store.kinds(db), state}

  defp broadcasting({:ok, %Job{} = job} = result) do
    broadcast(job)
    result
  end

  defp broadcasting(result), do: result

  defp broadcast(job), do: Phoenix.PubSub.broadcast(Butler.PubSub, @topic, {:job_changed, job})
end
