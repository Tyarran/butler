defmodule Butler.Test.QueueFixture do
  @moduledoc """
  Builds fixture MemPalace queue databases (`queue.sqlite3`) for tests.

  The schema mirrors the real daemon queue exactly (table, indexes, WAL mode).
  All data is **synthetic**: never copy content from a real palace here.
  """

  alias Exqlite.Sqlite3

  @schema [
    """
    CREATE TABLE jobs (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,
      payload_json TEXT NOT NULL,
      state TEXT NOT NULL,
      priority INTEGER NOT NULL DEFAULT 0,
      dedupe_key TEXT,
      created_at TEXT NOT NULL,
      started_at TEXT,
      finished_at TEXT,
      result_json TEXT,
      error_json TEXT,
      attempts INTEGER NOT NULL DEFAULT 0
    )
    """,
    "CREATE INDEX idx_jobs_state ON jobs(state, priority)",
    "CREATE INDEX idx_jobs_dedupe ON jobs(dedupe_key, state)",
    """
    CREATE UNIQUE INDEX idx_jobs_dedupe_active ON jobs(dedupe_key)
    WHERE state IN ('queued', 'running')
    """
  ]

  @columns ~w(id kind payload_json state priority dedupe_key created_at started_at
              finished_at result_json error_json attempts)a

  @json_columns ~w(payload_json result_json error_json)a

  @insert_sql "INSERT INTO jobs (#{Enum.join(@columns, ", ")}) VALUES (#{Enum.map_join(@columns, ", ", fn _ -> "?" end)})"

  @doc """
  Returns a fresh unique temporary directory, removed when the test exits.
  """
  @spec tmp_dir!() :: Path.t()
  def tmp_dir! do
    dir = Path.join(System.tmp_dir!(), "butler-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  @doc """
  Creates an empty queue database at `path` (parent directories included) in
  WAL mode and returns `path`.
  """
  @spec create!(Path.t()) :: Path.t()
  def create!(path) do
    File.mkdir_p!(Path.dirname(path))

    with_db(path, fn db ->
      :ok = Sqlite3.execute(db, "PRAGMA journal_mode=WAL")
      Enum.each(@schema, fn sql -> :ok = Sqlite3.execute(db, sql) end)
    end)

    path
  end

  @doc """
  Inserts a job into the database at `path` and returns its id.

  `attrs` is a map or keyword list overriding the synthetic defaults. The
  `payload_json`, `result_json` and `error_json` values may be given as maps
  (encoded to JSON) or raw strings (stored as is, e.g. to test malformed JSON).
  """
  @spec insert_job!(Path.t(), map() | keyword()) :: String.t()
  def insert_job!(path, attrs \\ %{}) do
    row = Map.merge(defaults(), Map.new(attrs))
    values = Enum.map(@columns, &encode(&1, Map.get(row, &1)))

    with_db(path, fn db ->
      {:ok, stmt} = Sqlite3.prepare(db, @insert_sql)
      :ok = Sqlite3.bind(stmt, values)
      :done = Sqlite3.step(db, stmt)
      :ok = Sqlite3.release(db, stmt)
    end)

    row.id
  end

  @doc """
  Returns the ISO8601 timestamp (`+00:00` suffix, like the daemon writes)
  `seconds_ago` seconds before now.
  """
  @spec iso_ago(non_neg_integer()) :: String.t()
  def iso_ago(seconds_ago) do
    DateTime.utc_now()
    |> DateTime.add(-seconds_ago, :second)
    |> DateTime.to_iso8601()
    |> String.replace("Z", "+00:00")
  end

  defp defaults do
    %{
      id: "job-#{System.unique_integer([:positive])}",
      kind: "mine",
      payload_json: %{"source" => "/tmp/synthetic/project", "mode" => "projects"},
      state: "queued",
      priority: 0,
      dedupe_key: nil,
      created_at: iso_ago(60),
      started_at: nil,
      finished_at: nil,
      result_json: nil,
      error_json: nil,
      attempts: 0
    }
  end

  defp encode(column, value)
       when column in @json_columns and not is_binary(value) and not is_nil(value),
       do: Jason.encode!(value)

  defp encode(_column, value), do: value

  defp with_db(path, fun) do
    {:ok, db} = Sqlite3.open(path, mode: [:readwrite, :create])

    try do
      fun.(db)
    after
      Sqlite3.close(db)
    end
  end
end
