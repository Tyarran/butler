defmodule Butler.Jobs.Store do
  @moduledoc """
  Read-only access to the daemon job queue (`queue.sqlite3`).

  The database is **always opened read-only** (`SQLITE_OPEN_READONLY` plus
  `PRAGMA query_only`); Butler never writes to it. A missing file is reported
  as `{:error, :not_found}` and is never created.

  The daemon writes in WAL mode, so readers do not block on it. A busy timeout
  is still set to absorb checkpoints.
  """

  alias Butler.Jobs.Job
  alias Exqlite.Sqlite3

  @default_limit 200
  @max_limit 1_000
  @busy_timeout_ms 2_000
  @states ~w(queued running succeeded failed cancelled)a
  @active_sql "state IN ('queued', 'running')"

  @type db_path :: Path.t()
  @type list_opt ::
          {:state, Job.state() | nil} | {:kind, String.t() | nil} | {:limit, pos_integer()}

  @doc """
  Lists jobs, active (queued/running) first, then newest first.

  Options: `:state` (one of the known states), `:kind` and `:limit`
  (default #{@default_limit}, capped at #{@max_limit}).
  """
  @spec list(db_path(), [list_opt()]) :: {:ok, [Job.t()]} | {:error, term()}
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
  @spec get(db_path(), String.t()) ::
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
  @spec counts(db_path()) :: {:ok, %{Job.state() => non_neg_integer()}} | {:error, term()}
  def counts(path) do
    zero = Map.new(@states, &{&1, 0})

    with {:ok, rows} <- rows(path, "SELECT state, COUNT(*) FROM jobs GROUP BY state") do
      {:ok, Enum.reduce(rows, zero, &add_count/2)}
    end
  end

  # Runs a parameterless read query and returns the raw rows.
  defp rows(path, sql) do
    result =
      with_connection(path, fn db ->
        with {:ok, stmt} <- Sqlite3.prepare(db, sql) do
          try do
            Sqlite3.fetch_all(db, stmt)
          after
            Sqlite3.release(db, stmt)
          end
        end
      end)

    case result do
      {:ok, inner} -> inner
      {:error, _reason} = error -> error
    end
  end

  defp add_count([state, count], acc) do
    case Enum.find(@states, &(Atom.to_string(&1) == state)) do
      nil -> acc
      known -> Map.put(acc, known, count)
    end
  end

  @doc "Distinct job kinds present in the queue, sorted."
  @spec kinds(db_path()) :: {:ok, [String.t()]} | {:error, term()}
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

  defp query(path, sql, params) do
    result =
      with_connection(path, fn db ->
        with {:ok, stmt} <- Sqlite3.prepare(db, sql) do
          try do
            with :ok <- Sqlite3.bind(stmt, params),
                 {:ok, columns} <- Sqlite3.columns(db, stmt),
                 {:ok, rows} <- Sqlite3.fetch_all(db, stmt) do
              {:ok, Enum.map(rows, &to_job(columns, &1))}
            end
          after
            Sqlite3.release(db, stmt)
          end
        end
      end)

    case result do
      {:ok, inner} -> inner
      {:error, _reason} = error -> error
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
