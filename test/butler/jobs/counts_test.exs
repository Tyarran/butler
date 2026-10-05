defmodule Butler.Jobs.CountsTest do
  use ExUnit.Case, async: true

  alias Butler.Jobs.Store
  alias Butler.Test.QueueFixture

  setup do
    path = QueueFixture.create!(Path.join(QueueFixture.tmp_dir!(), "queue.sqlite3"))
    {:ok, path: path}
  end

  @zero %{queued: 0, running: 0, succeeded: 0, failed: 0, cancelled: 0}

  test "returns all state keys at 0 for an empty queue", %{path: path} do
    assert Store.counts(path) == {:ok, @zero}
  end

  test "counts jobs per state", %{path: path} do
    for state <- ~w(queued succeeded succeeded failed failed failed cancelled) do
      QueueFixture.insert_job!(path, state: state)
    end

    assert Store.counts(path) ==
             {:ok, %{queued: 1, running: 0, succeeded: 2, failed: 3, cancelled: 1}}
  end

  test "ignores unknown states", %{path: path} do
    QueueFixture.insert_job!(path, state: "weird")
    assert Store.counts(path) == {:ok, @zero}
  end

  test "returns {:error, :not_found} for a missing database" do
    assert Store.counts(Path.join(QueueFixture.tmp_dir!(), "nope")) == {:error, :not_found}
  end
end
