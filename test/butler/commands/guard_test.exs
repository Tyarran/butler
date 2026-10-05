defmodule Butler.Commands.GuardTest do
  use ExUnit.Case, async: false

  alias Butler.Commands.Guard
  alias Butler.Jobs.Job
  alias Butler.Test.DaemonFixture
  alias Butler.Test.QueueFixture

  setup do
    {:ok, fixture: DaemonFixture.install!(running: true)}
  end

  describe "blocking?/1" do
    test "queued and running jobs block by default" do
      assert Guard.blocking?(%Job{id: "a", state: :queued})
      assert Guard.blocking?(%Job{id: "a", state: :running})
      refute Guard.blocking?(%Job{id: "a", state: :succeeded})
      refute Guard.blocking?(%Job{id: "a", state: :failed})
      refute Guard.blocking?(%Job{id: "a", state: :cancelled})
    end

    test "is driven by the :blocking_job_states configuration" do
      DaemonFixture.put_env!(blocking_job_states: [:running])

      refute Guard.blocking?(%Job{id: "a", state: :queued})
      assert Guard.blocking?(%Job{id: "a", state: :running})
      assert Guard.blocking_states() == [:running]
    end

    test "defaults to queued and running" do
      assert Guard.blocking_states() == [:queued, :running]
    end
  end

  describe "check/0" do
    test "is :ok on an empty queue" do
      assert Guard.check() == :ok
    end

    test "is :ok when only finished jobs exist", %{fixture: f} do
      for state <- ~w(succeeded failed cancelled),
          do: QueueFixture.insert_job!(f.queue, state: state)

      assert Guard.check() == :ok
    end

    test "is :ok when there is no queue database" do
      DaemonFixture.install!(queue: false)
      assert Guard.check() == :ok
    end

    test "returns the blocking jobs", %{fixture: f} do
      QueueFixture.insert_job!(f.queue, id: "q1", state: "queued")
      QueueFixture.insert_job!(f.queue, id: "r1", state: "running")
      QueueFixture.insert_job!(f.queue, id: "s1", state: "succeeded")

      assert {:blocked, jobs} = Guard.check()
      assert jobs |> Enum.map(& &1.id) |> Enum.sort() == ["q1", "r1"]
      assert Enum.all?(jobs, &match?(%Job{}, &1))
    end

    test "honours the configured states", %{fixture: f} do
      DaemonFixture.put_env!(blocking_job_states: [:running])
      QueueFixture.insert_job!(f.queue, id: "q1", state: "queued")
      assert Guard.check() == :ok

      QueueFixture.insert_job!(f.queue, id: "r1", state: "running")
      assert {:blocked, [%Job{id: "r1"}]} = Guard.check()
    end

    test "accepts an explicit queue path", %{fixture: f} do
      QueueFixture.insert_job!(f.queue, id: "q1", state: "queued")
      assert {:blocked, [%Job{id: "q1"}]} = Guard.check(f.queue)
    end

    test "an unreadable queue is an error, never a silent :ok", %{fixture: f} do
      File.write!(f.queue, "this is not a sqlite database")
      assert {:error, _reason} = Guard.check()
    end
  end
end
