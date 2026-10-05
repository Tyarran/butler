defmodule Butler.Test.QueueFixtureTest do
  use ExUnit.Case, async: true

  alias Butler.Test.QueueFixture
  alias Exqlite.Sqlite3

  setup do
    {:ok, path: Path.join(QueueFixture.tmp_dir!(), "queue.sqlite3")}
  end

  defp query(path, sql) do
    {:ok, db} = Sqlite3.open(path, mode: :readonly)
    {:ok, stmt} = Sqlite3.prepare(db, sql)
    {:ok, rows} = Sqlite3.fetch_all(db, stmt)
    Sqlite3.release(db, stmt)
    Sqlite3.close(db)
    rows
  end

  test "create!/1 builds the jobs table in WAL mode", %{path: path} do
    assert QueueFixture.create!(path) == path
    assert query(path, "PRAGMA journal_mode") == [["wal"]]

    columns = path |> query("PRAGMA table_info(jobs)") |> Enum.map(&Enum.at(&1, 1))

    assert columns ==
             ~w(id kind payload_json state priority dedupe_key created_at started_at
                finished_at result_json error_json attempts)
  end

  test "create!/1 builds the expected indexes", %{path: path} do
    QueueFixture.create!(path)

    names =
      path
      |> query("SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'jobs'")
      |> List.flatten()
      |> Enum.reject(&String.starts_with?(&1, "sqlite_"))
      |> Enum.sort()

    assert names == ["idx_jobs_dedupe", "idx_jobs_dedupe_active", "idx_jobs_state"]
  end

  test "insert_job!/2 inserts a row with overrides and JSON encoding", %{path: path} do
    QueueFixture.create!(path)

    id =
      QueueFixture.insert_job!(path,
        id: "j1",
        kind: "mcp_tool",
        state: "failed",
        error_json: %{"message" => "boom"}
      )

    assert id == "j1"

    assert query(path, "SELECT id, kind, state, error_json, attempts FROM jobs") ==
             [["j1", "mcp_tool", "failed", ~s({"message":"boom"}), 0]]
  end

  test "the unique active dedupe index rejects duplicates", %{path: path} do
    QueueFixture.create!(path)
    QueueFixture.insert_job!(path, dedupe_key: "k", state: "queued")

    assert_raise MatchError, fn ->
      QueueFixture.insert_job!(path, dedupe_key: "k", state: "running")
    end

    # A finished job with the same key is allowed.
    QueueFixture.insert_job!(path, dedupe_key: "k", state: "succeeded")
  end

  test "iso_ago/1 uses the +00:00 suffix" do
    assert QueueFixture.iso_ago(10) =~ ~r/^\d{4}-\d{2}-\d{2}T[\d:.]+\+00:00$/
  end
end
