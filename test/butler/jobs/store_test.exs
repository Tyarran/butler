defmodule Butler.Jobs.StoreTest do
  use ExUnit.Case, async: true

  alias Butler.Jobs.Job
  alias Butler.Jobs.Store
  alias Butler.Test.QueueFixture

  setup do
    path = Path.join(QueueFixture.tmp_dir!(), "queue.sqlite3")
    {:ok, db} = Store.open(path)
    on_exit(fn -> Store.close(db) end)
    {:ok, path: path, db: db}
  end

  defp ids({:ok, jobs}), do: Enum.map(jobs, & &1.id)

  describe "list/2" do
    test "returns Job structs", %{path: path, db: db} do
      QueueFixture.insert_job!(path, id: "a", state: "succeeded")

      assert {:ok, [%Job{id: "a", state: :succeeded}]} = Store.list(db)
    end

    test "returns an empty list for an empty queue", %{db: db} do
      assert Store.list(db) == {:ok, []}
    end

    test "puts active jobs first, then newest first", %{path: path, db: db} do
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

      assert ids(Store.list(db)) == ["new-running", "old-queued", "new-done", "old-done"]
    end

    test "filters by state", %{path: path, db: db} do
      QueueFixture.insert_job!(path, id: "a", state: "failed")
      QueueFixture.insert_job!(path, id: "b", state: "succeeded")

      assert ids(Store.list(db, state: :failed)) == ["a"]
    end

    test "filters by kind", %{path: path, db: db} do
      QueueFixture.insert_job!(path, id: "a", kind: "mine")
      QueueFixture.insert_job!(path, id: "b", kind: "mcp_tool")

      assert ids(Store.list(db, kind: "mcp_tool")) == ["b"]
    end

    test "applies the limit", %{path: path, db: db} do
      for n <- 1..5,
          do:
            QueueFixture.insert_job!(path,
              id: "j#{n}",
              state: "succeeded",
              created_at: QueueFixture.iso_ago(n)
            )

      assert length(ids(Store.list(db, limit: 2))) == 2
    end

    test "ignores nil filters", %{path: path, db: db} do
      QueueFixture.insert_job!(path, id: "a")
      assert ids(Store.list(db, state: nil, kind: nil)) == ["a"]
    end

    test "does not interpolate filter values into SQL", %{path: path, db: db} do
      QueueFixture.insert_job!(path, id: "a")
      assert Store.list(db, kind: "x' OR '1'='1") == {:ok, []}
    end

    test "rejects an unknown state filter", %{db: db} do
      assert Store.list(db, state: :bogus) == {:error, :invalid_state}
    end
  end

  describe "get/2" do
    test "returns the job", %{path: path, db: db} do
      QueueFixture.insert_job!(path, id: "abc", kind: "mcp_tool")
      assert {:ok, %Job{id: "abc", kind: "mcp_tool"}} = Store.get(db, "abc")
    end

    test "returns {:error, :job_not_found} for an unknown id", %{db: db} do
      assert Store.get(db, "missing") == {:error, :job_not_found}
    end
  end

  describe "kinds/1" do
    test "returns the distinct kinds, sorted", %{path: path, db: db} do
      QueueFixture.insert_job!(path, kind: "mine")
      QueueFixture.insert_job!(path, kind: "mcp_tool")
      QueueFixture.insert_job!(path, kind: "mine")

      assert Store.kinds(db) == {:ok, ["mcp_tool", "mine"]}
    end
  end

  describe "concurrent writer" do
    test "reads succeed while another process keeps writing (WAL)", %{path: path, db: db} do
      writer =
        Task.async(fn ->
          for n <- 1..200, do: QueueFixture.insert_job!(path, id: "w#{n}", state: "succeeded")
        end)

      results = for _ <- 1..100, do: Store.list(db)
      Task.await(writer, 30_000)

      assert Enum.all?(results, &match?({:ok, _}, &1))
      assert {:ok, jobs} = Store.list(db, limit: 1000)
      assert length(jobs) == 200
    end
  end
end
