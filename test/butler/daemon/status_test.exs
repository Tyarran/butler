defmodule Butler.Daemon.StatusTest do
  use ExUnit.Case, async: true

  alias Butler.Daemon.Locator
  alias Butler.Daemon.Status
  alias Butler.Test.QueueFixture

  @palace "/tmp/synthetic/palace"
  @zero %{queued: 0, running: 0, succeeded: 0, failed: 0, cancelled: 0}

  setup do
    tmp = QueueFixture.tmp_dir!()
    proc = Path.join(tmp, "proc")
    File.mkdir_p!(proc)

    {:ok, root: Path.join(tmp, "daemon"), proc: proc}
  end

  defp write_endpoint!(root, pid) do
    dir = Path.join(root, "abc")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "endpoint.json"),
      Jason.encode!(%{
        "host" => "127.0.0.1",
        "port" => 1,
        "pid" => pid,
        "palace_path" => @palace,
        "started_at" => "2026-01-01T10:00:00+00:00"
      })
    )

    dir
  end

  defp resolve(root, proc), do: Status.resolve(root: root, palace_path: @palace, proc_root: proc)

  test "is running when the PID is alive and the queue exists", %{root: root, proc: proc} do
    dir = write_endpoint!(root, 4321)
    QueueFixture.create!(Path.join(dir, "queue.sqlite3"))
    QueueFixture.insert_job!(Path.join(dir, "queue.sqlite3"), state: "running")
    File.mkdir_p!(Path.join(proc, "4321"))

    assert %Status{
             state: :running,
             pid: 4321,
             palace_path: @palace,
             started_at: ~U[2026-01-01 10:00:00Z],
             counts: %{running: 1, queued: 0}
           } = resolve(root, proc)
  end

  test "a stale endpoint (dead PID) is stopped, with the queue still readable", %{
    root: root,
    proc: proc
  } do
    dir = write_endpoint!(root, 4321)
    QueueFixture.create!(Path.join(dir, "queue.sqlite3"))
    QueueFixture.insert_job!(Path.join(dir, "queue.sqlite3"), state: "failed")

    status = resolve(root, proc)

    assert status.state == :stopped
    assert status.counts == %{@zero | failed: 1}
  end

  test "a live PID without a queue is stopped", %{root: root, proc: proc} do
    write_endpoint!(root, 4321)
    File.mkdir_p!(Path.join(proc, "4321"))

    status = resolve(root, proc)

    assert status.state == :stopped
    assert status.counts == nil
  end

  test "a cleanly stopped daemon (no endpoint) keeps its queue readable", %{
    root: root,
    proc: proc
  } do
    key = Locator.palace_key(@palace)
    queue = QueueFixture.create!(Path.join([root, key, "queue.sqlite3"]))
    QueueFixture.insert_job!(queue, state: "succeeded")

    status = resolve(root, proc)

    assert status.state == :stopped
    assert status.pid == nil
    assert status.counts == %{@zero | succeeded: 1}
  end

  test "nothing on disk is stopped with no counts", %{root: root, proc: proc} do
    assert %Status{state: :stopped, pid: nil, counts: nil, palace_path: @palace} =
             resolve(root, proc)
  end

  test "uses the real /proc by default: the BEAM's own PID is alive" do
    assert Status.pid_alive?(String.to_integer(System.pid()))
    refute Status.pid_alive?(nil)
  end
end
