defmodule Butler.Jobs.StoreTest do
  use ExUnit.Case, async: true

  alias Butler.Jobs.Job
  alias Butler.Jobs.Store
  alias Butler.Test.QueueFixture
  alias Exqlite.Sqlite3

  setup do
    path = QueueFixture.create!(Path.join(QueueFixture.tmp_dir!(), "queue.sqlite3"))
    {:ok, path: path}
  end

  defp ids({:ok, jobs}), do: Enum.map(jobs, & &1.id)

  describe "list/2" do
    test "returns Job structs", %{path: path} do
      QueueFixture.insert_job!(path, id: "a", state: "succeeded")

      assert {:ok, [%Job{id: "a", state: :succeeded}]} = Store.list(path)
    end

    test "returns an empty list for an empty queue", %{path: path} do
      assert Store.list(path) == {:ok, []}
    end

    test "puts active jobs first, then newest first", %{path: path} do
      QueueFixture.insert_job!(path,
        id: "old-done",
        state: "succeeded",
        created_at: QueueFixture.iso_ago(900)
      )

      QueueFixture.insert_job!(path,
        id: "new-done",
        state: "failed",
        created_at: QueueFixture.iso_ago(100)
      )

      QueueFixture.insert_job!(path,
        id: "old-queued",
        state: "queued",
        created_at: QueueFixture.iso_ago(500)
      )

      QueueFixture.insert_job!(path,
        id: "new-running",
        state: "running",
        created_at: QueueFixture.iso_ago(300)
      )

      assert ids(Store.list(path)) == ["new-running", "old-queued", "new-done", "old-done"]
    end

    test "filters by state", %{path: path} do
      QueueFixture.insert_job!(path, id: "a", state: "failed")
      QueueFixture.insert_job!(path, id: "b", state: "succeeded")

      assert ids(Store.list(path, state: :failed)) == ["a"]
    end

    test "filters by kind", %{path: path} do
      QueueFixture.insert_job!(path, id: "a", kind: "mine")
      QueueFixture.insert_job!(path, id: "b", kind: "mcp_tool")

      assert ids(Store.list(path, kind: "mcp_tool")) == ["b"]
    end

    test "applies the limit", %{path: path} do
      for n <- 1..5,
          do:
            QueueFixture.insert_job!(path,
              id: "j#{n}",
              state: "succeeded",
              created_at: QueueFixture.iso_ago(n)
            )

      assert length(ids(Store.list(path, limit: 2))) == 2
    end

    test "ignores nil filters", %{path: path} do
      QueueFixture.insert_job!(path, id: "a")
      assert ids(Store.list(path, state: nil, kind: nil)) == ["a"]
    end

    test "does not interpolate filter values into SQL", %{path: path} do
      QueueFixture.insert_job!(path, id: "a")
      assert Store.list(path, kind: "x' OR '1'='1") == {:ok, []}
    end

    test "rejects an unknown state filter", %{path: path} do
      assert Store.list(path, state: :bogus) == {:error, :invalid_state}
    end

    test "returns {:error, :not_found} when the file does not exist" do
      missing = Path.join(QueueFixture.tmp_dir!(), "nope.sqlite3")

      assert Store.list(missing) == {:error, :not_found}
      refute File.exists?(missing), "a missing database must not be created"
    end
  end

  describe "get/2" do
    test "returns the job", %{path: path} do
      QueueFixture.insert_job!(path, id: "abc", kind: "mcp_tool")
      assert {:ok, %Job{id: "abc", kind: "mcp_tool"}} = Store.get(path, "abc")
    end

    test "returns {:error, :job_not_found} for an unknown id", %{path: path} do
      assert Store.get(path, "missing") == {:error, :job_not_found}
    end

    test "returns {:error, :not_found} when the file does not exist" do
      assert Store.get(Path.join(QueueFixture.tmp_dir!(), "nope"), "x") == {:error, :not_found}
    end
  end

  describe "kinds/1" do
    test "returns the distinct kinds, sorted", %{path: path} do
      QueueFixture.insert_job!(path, kind: "mine")
      QueueFixture.insert_job!(path, kind: "mcp_tool")
      QueueFixture.insert_job!(path, kind: "mine")

      assert Store.kinds(path) == {:ok, ["mcp_tool", "mine"]}
    end

    test "returns {:error, :not_found} when the file does not exist" do
      assert Store.kinds(Path.join(QueueFixture.tmp_dir!(), "nope")) == {:error, :not_found}
    end
  end

  describe "read-only guarantee" do
    test "any write attempt fails and leaves the data untouched", %{path: path} do
      QueueFixture.insert_job!(path, id: "keep")

      for sql <- [
            "DELETE FROM jobs",
            "UPDATE jobs SET state = 'failed'",
            "INSERT INTO jobs (id, kind, payload_json, state, created_at) VALUES ('x','mine','{}','queued','2026-01-01T00:00:00+00:00')",
            "DROP TABLE jobs"
          ] do
        assert {:ok, {:error, reason}} = Store.with_connection(path, &Sqlite3.execute(&1, sql))
        assert reason =~ ~r/readonly|read-only|read only/i
      end

      assert ids(Store.list(path)) == ["keep"]
    end
  end

  describe "concurrent writer" do
    test "reads succeed while another process keeps writing (WAL)", %{path: path} do
      writer =
        Task.async(fn ->
          for n <- 1..200, do: QueueFixture.insert_job!(path, id: "w#{n}", state: "succeeded")
        end)

      results = for _ <- 1..100, do: Store.list(path)
      Task.await(writer, 30_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert {:ok, jobs} = Store.list(path, limit: 1000)
      assert length(jobs) == 200
    end
  end
end
