defmodule Butler.Jobs.Store do
  @moduledoc """
  SQLite access to a job queue (`queue.sqlite3`), in two modes never mixed on
  the same file:

    * **Read-only, by path** (`list/2`, `get/2`, `counts/1`, `kinds/1` given a
      path): opens with `SQLITE_OPEN_READONLY` plus `PRAGMA query_only` and never
      creates the file (`{:error, :not_found}`). Used to display the legacy
      Python daemon queue until the cutover; Butler never writes to that file.
    * **Read-write, by handle** (`open/1`, then `enqueue/3`, `claim_next/2`, ...):
      Butler's **own** queue in its state directory (see `Butler.Paths`).
      `open/1` creates the directory (mode 700) and the database (mode 600, WAL),
      applies the schema and refuses a database whose `user_version` is newer
      than known. The read functions accept such a handle too. The handle must
      be owned by a single process (the `Queue` server, phase 2).

  Timestamps written by Butler are UTC ISO-8601 with millisecond precision and a
  `Z` suffix, so they sort lexicographically.
  """

  alias Butler.Jobs.Job
  alias Butler.Paths
  alias Exqlite.Sqlite3

  @default_limit 200
  @max_limit 1_000
  @busy_timeout_ms 2_000
  @states ~w(queued running succeeded failed cancelled)a
  @active_sql "state IN ('queued', 'running')"
  @user_version 1
  @write_busy_timeout_ms 5_000
  @max_attempts 3
  @schema [
    """
    CREATE TABLE IF NOT EXISTS jobs (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      state TEXT NOT NULL CHECK (state IN ('queued','running','succeeded','failed','cancelled')),
      priority INTEGER NOT NULL DEFAULT 0,
      dedupe_key TEXT,
      created_at TEXT NOT NULL,
      started_at TEXT,
      finished_at TEXT,
      result_json TEXT,
      error_json TEXT,
      attempts INTEGER NOT NULL DEFAULT 0,
      os_pid INTEGER
    )
    """,
    "CREATE INDEX IF NOT EXISTS idx_jobs_state ON jobs(state, priority)",
    """
    CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_dedupe_active ON jobs(dedupe_key)
    WHERE dedupe_key IS NOT NULL AND state IN ('queued','running')
    """
  ]

  @type db_path :: Path.t()
  @type db :: Sqlite3.db()
  @type target :: db_path() | db()
  @type list_opt ::
          {:state, Job.state() | nil} | {:kind, String.t() | nil} | {:limit, pos_integer()}

  @doc """
  Lists jobs, active (queued/running) first, then newest first.

  Options: `:state` (one of the known states), `:kind` and `:limit`
  (default #{@default_limit}, capped at #{@max_limit}).
  """
  @spec list(target(), [list_opt()]) :: {:ok, [Job.t()]} | {:error, term()}
  def list(path, opts \\ []) do
    state = opts[:state]
    kind = opts[:kind]
    limit = opts |> Keyword.get(:limit, @default_limit) |> clamp_limit()

    if is_nil(state) or state in @states do
      {where, params} = filters(state, kind)

      sql =
        "SELECT * FROM jobs#{where} ORDER BY (#{@active_sql}) DESC, created_at DESC LIMIT ?"

      query(path, sql, params ++ [limit])
    else
      {:error, :invalid_state}
    end
  end

  @doc "Fetches a job by id."
  @spec get(target(), String.t()) ::
          {:ok, Job.t()} | {:error, :not_found | :job_not_found | term()}
  def get(path, id) do
    case query(path, "SELECT * FROM jobs WHERE id = ? LIMIT 1", [id]) do
      {:ok, [job]} -> {:ok, job}
      {:ok, []} -> {:error, :job_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Number of jobs per state. The result always has the five keys `:queued`, `:cancelled`,
  `:running`, `:succeeded` and `:failed`, defaulting to 0.
  """
  @spec counts(target()) :: {:ok, %{Job.state() => non_neg_integer()}} | {:error, term()}
  def counts(path) do
    zero = Map.new(@states, &{&1, 0})

    with {:ok, rows} <- rows(path, "SELECT state, COUNT(*) FROM jobs GROUP BY state") do
      {:ok, Enum.reduce(rows, zero, &add_count/2)}
    end
  end

  # Runs a parameterless read query and returns the raw rows.
  defp rows(target, sql) do
    read(target, fn db ->
      with {:ok, stmt} <- Sqlite3.prepare(db, sql) do
        try do
          Sqlite3.fetch_all(db, stmt)
        after
          Sqlite3.release(db, stmt)
        end
      end
    end)
  end

  # Runs `fun` on a read-only connection (path) or on the given handle.
  defp read(path, fun) when is_binary(path) do
    case with_connection(path, fun) do
      {:ok, inner} -> inner
      {:error, _reason} = error -> error
    end
  end

  defp read(db, fun), do: fun.(db)

  defp add_count([state, count], acc) do
    case Enum.find(@states, &(Atom.to_string(&1) == state)) do
      nil -> acc
      known -> Map.put(acc, known, count)
    end
  end

  @doc "Distinct job kinds present in the queue, sorted."
  @spec kinds(target()) :: {:ok, [String.t()]} | {:error, term()}
  def kinds(path) do
    with {:ok, rows} <- rows(path, "SELECT DISTINCT kind FROM jobs ORDER BY kind") do
      {:ok, List.flatten(rows)}
    end
  end

  @doc """
  Runs `fun` with a read-only connection to the queue database.

  Returns `{:ok, fun_result}`, or `{:error, :not_found}` when the file does
  not exist, or `{:error, reason}` when it cannot be opened.
  """
  @spec with_connection(db_path(), (Sqlite3.db() -> result)) :: {:ok, result} | {:error, term()}
        when result: term()
  def with_connection(path, fun) do
    if File.regular?(path) do
      open_and_run(path, fun)
    else
      {:error, :not_found}
    end
  end

  defp open_and_run(path, fun) do
    case Sqlite3.open(path, mode: :readonly) do
      {:ok, db} ->
        try do
          with :ok <- Sqlite3.set_busy_timeout(db, @busy_timeout_ms),
               :ok <- Sqlite3.execute(db, "PRAGMA query_only = ON") do
            {:ok, fun.(db)}
          end
        after
          Sqlite3.close(db)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query(target, sql, params) do
    read(target, fn db ->
      with {:ok, columns, rows} <- select(db, sql, params) do
        {:ok, Enum.map(rows, &to_job(columns, &1))}
      end
    end)
  end

  # Prepares, binds and fully fetches a statement.
  defp select(db, sql, params) do
    with {:ok, stmt} <- Sqlite3.prepare(db, sql) do
      try do
        with :ok <- Sqlite3.bind(stmt, params),
             {:ok, columns} <- Sqlite3.columns(db, stmt),
             {:ok, rows} <- Sqlite3.fetch_all(db, stmt) do
          {:ok, columns, rows}
        end
      after
        Sqlite3.release(db, stmt)
      end
    end
  end

  # Runs a statement that returns no rows and reports the number of changed rows.
  defp modify(db, sql, params) do
    with {:ok, _columns, _rows} <- select(db, sql, params) do
      Sqlite3.changes(db)
    end
  end

  # -- Read-write queue (Butler's own database) -------------------------------

  @doc """
  Opens (and creates when missing) Butler's own queue database for reading and
  writing.

  The parent directory gets mode 700, the database and its `-wal`/`-shm` files
  mode 600. Returns `{:error, {:unsupported_user_version, version}}` when the
  database was written by a newer Butler.
  """
  @spec open(db_path()) :: {:ok, db()} | {:error, term()}
  def open(path) do
    with :ok <- Paths.ensure_dir(Path.dirname(path)),
         :ok <- File.write(path, "", [:append]),
         :ok <- File.chmod(path, Paths.file_mode()),
         {:ok, db} <- Sqlite3.open(path) do
      case init(db) do
        :ok ->
          secure_files(path)
          {:ok, db}

        {:error, _reason} = error ->
          Sqlite3.close(db)
          error
      end
    end
  end

  @doc "Closes a handle returned by `open/1`."
  @spec close(db()) :: :ok | {:error, term()}
  def close(db), do: Sqlite3.close(db)

  defp init(db) do
    with :ok <- Sqlite3.set_busy_timeout(db, @write_busy_timeout_ms),
         {:ok, _columns, [[version]]} <- select(db, "PRAGMA user_version", []),
         :ok <- check_version(version),
         {:ok, _columns, _rows} <- select(db, "PRAGMA journal_mode = WAL", []),
         :ok <- Enum.reduce_while(@schema, :ok, &run_schema(db, &1, &2)) do
      Sqlite3.execute(db, "PRAGMA user_version = #{@user_version}")
    end
  end

  defp check_version(version) when version <= @user_version, do: :ok
  defp check_version(version), do: {:error, {:unsupported_user_version, version}}

  defp run_schema(db, sql, :ok) do
    case Sqlite3.execute(db, sql) do
      :ok -> {:cont, :ok}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp secure_files(path) do
    for file <- [path, path <> "-wal", path <> "-shm"], File.exists?(file) do
      File.chmod(file, Paths.file_mode())
    end

    :ok
  end

  @doc """
  Inserts a queued job.

  `attrs`: `:kind` (required), `:payload` (JSON-encodable, default `%{}`),
  `:dedupe_key` and `:priority` (default 0). When a queued or running job
  already carries the same `dedupe_key`, nothing is inserted and that job is
  returned with `:deduplicated`. Options: `:id`, `:now`.
  """
  @spec enqueue(db(), map(), keyword()) ::
          {:ok, Job.t(), :created | :deduplicated} | {:error, term()}
  def enqueue(db, %{kind: kind} = attrs, opts \\ []) when is_binary(kind) do
    id = Keyword.get_lazy(opts, :id, &new_id/0)
    dedupe_key = Map.get(attrs, :dedupe_key)

    sql = """
    INSERT INTO jobs (id, kind, payload_json, state, priority, dedupe_key, created_at)
    VALUES (?, ?, ?, 'queued', ?, ?, ?)
    ON CONFLICT (dedupe_key) WHERE dedupe_key IS NOT NULL AND state IN ('queued', 'running')
    DO NOTHING
    """

    with {:ok, payload} <- Jason.encode(Map.get(attrs, :payload, %{})),
         params = [id, kind, payload, Map.get(attrs, :priority, 0), dedupe_key, timestamp(opts)],
         {:ok, changed} <- modify(db, sql, params) do
      inserted_or_existing(db, changed, id, dedupe_key)
    end
  end

  defp inserted_or_existing(db, 1, id, _dedupe_key) do
    with {:ok, job} <- get(db, id), do: {:ok, job, :created}
  end

  defp inserted_or_existing(db, 0, _id, dedupe_key) when is_binary(dedupe_key) do
    sql = "SELECT * FROM jobs WHERE dedupe_key = ? AND #{@active_sql} LIMIT 1"

    case query(db, sql, [dedupe_key]) do
      {:ok, [job]} -> {:ok, job, :deduplicated}
      {:ok, []} -> {:error, :not_inserted}
      {:error, _reason} = error -> error
    end
  end

  defp inserted_or_existing(_db, 0, _id, _dedupe_key), do: {:error, :not_inserted}

  @doc """
  Atomically claims the next queued job (`priority DESC, created_at ASC, rowid`),
  skipping `exclude_ids`: it becomes `running`, `attempts` is incremented and
  the previous error cleared. Returns `{:ok, nil}` when nothing is claimable.
  """
  @spec claim_next(db(), [String.t()], keyword()) :: {:ok, Job.t() | nil} | {:error, term()}
  def claim_next(db, exclude_ids \\ [], opts \\ []) do
    {excluded_sql, params} = exclusion(exclude_ids)

    select_sql =
      "SELECT id FROM jobs WHERE state = 'queued'#{excluded_sql} " <>
        "ORDER BY priority DESC, created_at ASC, rowid ASC LIMIT 1"

    update_sql =
      "UPDATE jobs SET state = 'running', started_at = ?, finished_at = NULL, " <>
        "attempts = attempts + 1, error_json = NULL, os_pid = NULL WHERE id = ?"

    transaction(db, fn ->
      case select(db, select_sql, params) do
        {:ok, _columns, rows} -> claim_row(db, rows, update_sql, timestamp(opts))
        {:error, _reason} = error -> error
      end
    end)
  end

  defp claim_row(_db, [], _update_sql, _now), do: {:ok, nil}

  defp claim_row(db, [[id]], update_sql, now) do
    with {:ok, 1} <- modify(db, update_sql, [now, id]), do: get(db, id)
  end

  defp exclusion([]), do: {"", []}

  defp exclusion(ids),
    do: {" AND id NOT IN (#{Enum.map_join(ids, ", ", fn _ -> "?" end)})", ids}

  @doc "Records the OS process id of the running job `id`."
  @spec set_os_pid(db(), String.t(), non_neg_integer()) :: {:ok, Job.t()} | {:error, term()}
  def set_os_pid(db, id, os_pid) when is_integer(os_pid) do
    update_running(db, id, "UPDATE jobs SET os_pid = ? WHERE id = ? AND state = 'running'", [
      os_pid,
      id
    ])
  end

  @doc """
  Moves the running job `id` to a terminal state (`:succeeded`, `:failed` or
  `:cancelled`) with an optional `:result` and `:error` (JSON-encodable).

  Guarded with `state = 'running'`: `{:error, :not_running}` when the job is no
  longer running (e.g. cancelled meanwhile). Options: `:now`.
  """
  @spec finish(db(), String.t(), :succeeded | :failed | :cancelled, map(), keyword()) ::
          {:ok, Job.t()} | {:error, term()}
  def finish(db, id, state, attrs \\ %{}, opts \\ [])
      when state in [:succeeded, :failed, :cancelled] do
    sql =
      "UPDATE jobs SET state = ?, finished_at = ?, result_json = ?, error_json = ?, " <>
        "os_pid = NULL WHERE id = ? AND state = 'running'"

    with {:ok, result} <- encode_json(Map.get(attrs, :result)),
         {:ok, error} <- encode_json(Map.get(attrs, :error)) do
      params = [Atom.to_string(state), timestamp(opts), result, error, id]
      update_running(db, id, sql, params)
    end
  end

  @doc """
  Puts the running job `id` back in `queued` and refunds the attempt, recording
  `error`. Guarded on `state = 'running'` and on the `started_at` of the claim
  (`claimed_started_at`, a `DateTime` or ISO string), so a stale caller cannot
  touch a job that was claimed again.
  """
  @spec defer(db(), String.t(), DateTime.t() | String.t(), term()) ::
          {:ok, Job.t()} | {:error, term()}
  def defer(db, id, claimed_started_at, error) do
    sql =
      "UPDATE jobs SET state = 'queued', started_at = NULL, os_pid = NULL, " <>
        "attempts = MAX(attempts - 1, 0), error_json = ? " <>
        "WHERE id = ? AND state = 'running' AND started_at = ?"

    with {:ok, error_json} <- encode_json(error) do
      update_running(db, id, sql, [error_json, id, timestamp(now: claimed_started_at)])
    end
  end

  defp update_running(db, id, sql, params) do
    case modify(db, sql, params) do
      {:ok, 1} -> get(db, id)
      {:ok, 0} -> {:error, :not_running}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  Cancels a job. A queued job becomes `cancelled` immediately; a running job is
  returned unchanged (still `:running`) for the worker to stop and finish.
  """
  @spec cancel(db(), String.t(), keyword()) ::
          {:ok, Job.t()} | {:error, :job_not_found | :not_cancellable | term()}
  def cancel(db, id, opts \\ []) do
    with {:ok, job} <- get(db, id), do: cancel_job(db, job, opts)
  end

  defp cancel_job(db, %Job{state: :queued, id: id}, opts) do
    sql = "UPDATE jobs SET state = 'cancelled', finished_at = ? WHERE id = ? AND state = 'queued'"

    with {:ok, 1} <- modify(db, sql, [timestamp(opts), id]), do: get(db, id)
  end

  defp cancel_job(_db, %Job{state: :running} = job, _opts), do: {:ok, job}
  defp cancel_job(_db, %Job{}, _opts), do: {:error, :not_cancellable}

  @doc """
  Startup recovery of jobs left `running` by a crash.

  Jobs of an idempotent kind (`idempotent_kinds`) go back to `queued` while
  they have fewer than `:max_attempts` (default #{@max_attempts}) attempts;
  otherwise, and for every other kind, they become `failed`. Returns the
  number of re-queued and failed jobs. Options: `:max_attempts`, `:now`.
  """
  @spec recover_running(db(), [String.t()], keyword()) ::
          {:ok, %{requeued: non_neg_integer(), failed: non_neg_integer()}} | {:error, term()}
  def recover_running(db, idempotent_kinds, opts \\ []) do
    max_attempts = Keyword.get(opts, :max_attempts, @max_attempts)
    now = timestamp(opts)
    kinds_sql = Enum.map_join(idempotent_kinds, ", ", fn _ -> "?" end)

    requeue_sql =
      "UPDATE jobs SET state = 'queued', started_at = NULL, os_pid = NULL " <>
        "WHERE state = 'running' AND kind IN (#{kinds_sql}) AND attempts < ?"

    exhausted_sql =
      "UPDATE jobs SET state = 'failed', finished_at = ?, os_pid = NULL, error_json = ? " <>
        "WHERE state = 'running' AND kind IN (#{kinds_sql})"

    interrupted_sql =
      "UPDATE jobs SET state = 'failed', finished_at = ?, os_pid = NULL, error_json = ? " <>
        "WHERE state = 'running'"

    exhausted = Jason.encode!(%{class: "MaxAttemptsExceeded", message: "max attempts reached"})

    interrupted =
      Jason.encode!(%{
        class: "Interrupted",
        message: "interrupted: Butler stopped while the job was running"
      })

    transaction(db, fn ->
      with {:ok, requeued} <- modify(db, requeue_sql, idempotent_kinds ++ [max_attempts]),
           {:ok, exhausted_count} <-
             modify(db, exhausted_sql, [now, exhausted | idempotent_kinds]),
           {:ok, interrupted_count} <- modify(db, interrupted_sql, [now, interrupted]) do
        {:ok, %{requeued: requeued, failed: exhausted_count + interrupted_count}}
      end
    end)
  end

  @doc """
  Deletes terminal jobs (and their payloads) finished more than `days` days ago.
  Returns the number of deleted jobs. Options: `:now`.
  """
  @spec prune_terminal(db(), pos_integer(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def prune_terminal(db, days, opts \\ []) when is_integer(days) and days > 0 do
    now = opts |> Keyword.get_lazy(:now, &DateTime.utc_now/0) |> DateTime.add(-days * 86_400)

    modify(
      db,
      "DELETE FROM jobs WHERE state IN ('succeeded', 'failed', 'cancelled') AND finished_at < ?",
      [timestamp(now: now)]
    )
  end

  defp transaction(db, fun) do
    with :ok <- Sqlite3.execute(db, "BEGIN IMMEDIATE"), do: finish_transaction(db, fun.())
  end

  defp finish_transaction(db, {:error, _reason} = error) do
    Sqlite3.execute(db, "ROLLBACK")
    error
  end

  defp finish_transaction(db, result) do
    with :ok <- Sqlite3.execute(db, "COMMIT"), do: result
  end

  defp encode_json(nil), do: {:ok, nil}
  defp encode_json(value), do: Jason.encode(value)

  defp new_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # UTC ISO-8601, millisecond precision, `Z` suffix (sortable as text).
  defp timestamp(opts) do
    case Keyword.get_lazy(opts, :now, &DateTime.utc_now/0) do
      value when is_binary(value) -> value
      %DateTime{} = value -> value |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    end
  end

  defp to_job(columns, row), do: columns |> Enum.zip(row) |> Map.new() |> Job.from_row()

  defp filters(state, kind) do
    clauses =
      [
        state && {"state = ?", Atom.to_string(state)},
        kind && {"kind = ?", kind}
      ]
      |> Enum.filter(& &1)

    case clauses do
      [] ->
        {"", []}

      _ ->
        {" WHERE " <> Enum.map_join(clauses, " AND ", &elem(&1, 0)),
         Enum.map(clauses, &elem(&1, 1))}
    end
  end

  defp clamp_limit(limit) when is_integer(limit) and limit > 0, do: min(limit, @max_limit)
  defp clamp_limit(_limit), do: @default_limit
end
