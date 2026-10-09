defmodule Butler.Jobs.CountsTest do
  use ExUnit.Case, async: true

  alias Butler.Jobs.Store
  alias Butler.Test.QueueFixture

  setup do
    path = Path.join(QueueFixture.tmp_dir!(), "queue.sqlite3")
    {:ok, db} = Store.open(path)
    on_exit(fn -> Store.close(db) end)
    {:ok, path: path, db: db}
  end

  @zero %{queued: 0, running: 0, succeeded: 0, failed: 0, cancelled: 0}

  test "returns all state keys at 0 for an empty queue", %{db: db} do
    assert Store.counts(db) == {:ok, @zero}
  end

  test "counts jobs per state", %{path: path, db: db} do
    for state <- ~w(queued succeeded succeeded failed failed failed cancelled) do
      QueueFixture.insert_job!(path, state: state)
    end

    assert Store.counts(db) ==
             {:ok, %{queued: 1, running: 0, succeeded: 2, failed: 3, cancelled: 1}}
  end
end
