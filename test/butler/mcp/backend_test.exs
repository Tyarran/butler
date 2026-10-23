defmodule Butler.MCP.BackendTest do
  use ExUnit.Case, async: true

  alias Butler.MCP.Backend
  alias Butler.MCP.Worker
  alias Butler.Test.QueueFixture

  @fake Path.expand("../../support/fake_mcp.sh", __DIR__)

  defp start_backend!(opts \\ []) do
    topic = "butler:mcp:test:#{System.unique_integer([:positive])}"
    Phoenix.PubSub.subscribe(Butler.PubSub, topic)
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one}, id: make_ref())

    opts =
      Keyword.merge(
        [
          id: :light,
          bin: @fake,
          args: [],
          env: %{},
          worker_supervisor: supervisor,
          topic: topic,
          pool_size: 3,
          idle_rotation_ms: 60_000,
          max_start_failures: 3,
          startup_timeout_ms: 5_000,
          request_timeout_ms: 5_000
        ],
        opts
      )

    start_supervised!({Backend, opts}, id: make_ref())
  end

  # Waits for a snapshot satisfying `fun`, driven by the PubSub notifications.
  defp await_status(backend, fun, timeout \\ 5_000) do
    snapshot = Backend.status(backend)

    if fun.(snapshot) do
      snapshot
    else
      receive do
        {:mcp_changed, _id} -> await_status(backend, fun, timeout)
      after
        timeout -> flunk("condition never met, last snapshot: #{inspect(snapshot)}")
      end
    end
  end

  defp await_ready(backend), do: await_status(backend, &(&1.status == :ready))

  defp pids(snapshot), do: Enum.map(snapshot.workers, & &1.pid)
  defp os_pids(snapshot), do: Enum.map(snapshot.workers, & &1.os_pid)

  defp request(method), do: %{"jsonrpc" => "2.0", "id" => 1, "method" => method}

  defp wait_dead(os_pid, tries \\ 300) do
    cond do
      not File.exists?("/proc/#{os_pid}") ->
        :ok

      tries == 0 ->
        flunk("OS process #{os_pid} is still alive")

      true ->
        pause(10)
        wait_dead(os_pid, tries - 1)
    end
  end

  defp pause(ms) do
    receive do
    after
      ms -> :ok
    end
  end

  describe "start-up" do
    test "starts a pool of ready workers" do
      backend = start_backend!()

      snapshot = await_ready(backend)

      assert snapshot.pool_size == 3
      assert snapshot.ready == 3
      assert length(Enum.uniq(pids(snapshot))) == 3
      assert length(Enum.uniq(os_pids(snapshot))) == 3
      assert Enum.all?(snapshot.workers, &(&1.phase == :ready and &1.pending == 0))
      assert snapshot.failures == 0
      assert is_integer(snapshot.next_rotation_at)
    end

    test "checkout waits for the first worker" do
      backend = start_backend!()

      assert {:ok, worker} = Backend.checkout(backend)
      assert {:ok, %{"result" => %{"method" => "ping"}}} = Worker.call(worker, request("ping"))
    end

    test "checkout counts requests, record_error counts errors" do
      backend = start_backend!()
      {:ok, _worker} = Backend.checkout(backend)
      {:ok, _worker} = Backend.checkout(backend)
      Backend.record_error(backend)

      assert %{requests: 2, errors: 1} = Backend.status(backend)
    end
  end

  describe "round-robin" do
    test "checkouts cycle through every ready worker" do
      backend = start_backend!()
      snapshot = await_ready(backend)

      picked = for _i <- 1..6, do: elem(Backend.checkout(backend), 1)

      assert Enum.take(picked, 3) == Enum.drop(picked, 3)
      assert Enum.sort(Enum.take(picked, 3)) == Enum.sort(pids(snapshot))
    end

    test "waiting checkouts are all served" do
      backend = start_backend!()

      workers =
        1..6
        |> Enum.map(fn _i -> Task.async(fn -> Backend.checkout(backend) end) end)
        |> Task.await_many()

      assert Enum.all?(workers, &match?({:ok, pid} when is_pid(pid), &1))
      assert %{requests: 6} = Backend.status(backend)
    end
  end

  describe "rotation" do
    test "the whole pool is replaced after the idle delay" do
      backend = start_backend!(idle_rotation_ms: 300)
      first = await_ready(backend)

      second = await_status(backend, &(&1.rotations >= 1 and &1.status == :ready))

      assert second.pool_size == 3
      assert Enum.all?(pids(second), &(&1 not in pids(first)))
      Enum.each(os_pids(first), &wait_dead/1)
    end

    test "is off when the idle delay is 0" do
      backend = start_backend!(idle_rotation_ms: 0)
      first = await_ready(backend)

      assert first.next_rotation_at == nil
      {:ok, _worker} = Backend.checkout(backend)
      pause(300)

      second = Backend.status(backend)
      assert second.next_rotation_at == nil
      assert second.rotations == 0
      assert pids(second) == pids(first)
    end

    test "is postponed while a request is in flight" do
      backend = start_backend!(idle_rotation_ms: 300)
      first = await_ready(backend)
      {:ok, worker} = Backend.checkout(backend)

      task = Task.async(fn -> Worker.call(worker, request("slow")) end)
      pause(350)

      second = Backend.status(backend)
      assert second.rotations == 0
      assert pids(second) == pids(first)
      assert {:ok, _answer} = Task.await(task)
    end

    test "requests keep the backend from rotating" do
      backend = start_backend!(idle_rotation_ms: 700)
      await_ready(backend)

      for _i <- 1..5 do
        {:ok, _worker} = Backend.checkout(backend)
        pause(200)
      end

      assert %{rotations: 0} = Backend.status(backend)
    end

    test "restart replaces the whole pool, even with the rotation off" do
      backend = start_backend!(idle_rotation_ms: 0)
      first = await_ready(backend)

      assert :ok = Backend.restart(backend)
      second = await_status(backend, &(&1.rotations == 1 and &1.status == :ready))

      assert Enum.all?(pids(second), &(&1 not in pids(first)))
      Enum.each(os_pids(first), &wait_dead/1)
    end

    test "checkouts during a restart wait for a fresh worker" do
      backend = start_backend!()
      first = await_ready(backend)

      assert :ok = Backend.restart(backend)
      assert {:ok, worker} = Backend.checkout(backend)
      assert worker not in pids(first)
    end
  end

  describe "crash" do
    test "only the crashed worker is replaced" do
      backend = start_backend!()
      first = await_ready(backend)
      {:ok, worker} = Backend.checkout(backend)

      assert {:error, {:backend_exited, 1}} = Worker.call(worker, request("crash"))

      second = await_status(backend, &(&1.status == :ready and worker not in pids(&1)))
      assert second.rotations == 0
      assert length(pids(second) -- pids(first)) == 1
      assert length(pids(second) -- [worker]) == 3

      assert {:ok, other} = Backend.checkout(backend)
      assert {:ok, _answer} = Worker.call(other, request("ping"))
    end

    test "a killed worker is replaced and the others are kept" do
      backend = start_backend!()
      first = await_ready(backend)
      [victim | survivors] = first.workers

      {_output, 0} = System.cmd("kill", ["-KILL", Integer.to_string(victim.os_pid)])

      second = await_status(backend, &(&1.status == :ready and victim.pid not in pids(&1)))
      assert Enum.all?(Enum.map(survivors, & &1.pid), &(&1 in pids(second)))
    end
  end

  describe "failure" do
    test "gives up after max_start_failures and reports the cause" do
      backend = start_backend!(args: ["exit_on_start"])

      snapshot = await_status(backend, &(&1.status == :failed))

      assert snapshot.failures >= 3
      assert snapshot.last_error == {:exit_status, 3}
      assert snapshot.workers == []
      assert {:error, {:failed, {:exit_status, 3}}} = Backend.checkout(backend)
    end

    test "reports a missing executable" do
      backend = start_backend!(bin: "/nonexistent/butler-test/nope")

      snapshot = await_status(backend, &(&1.status == :failed))

      assert snapshot.last_error == {:executable_not_found, "/nonexistent/butler-test/nope"}
    end

    test "waiting callers get the failure" do
      backend = start_backend!(args: ["exit_on_start"])
      assert {:error, {:failed, _reason}} = Backend.checkout(backend)
    end

    test "restart leaves the failed state once the cause is fixed" do
      dir = QueueFixture.tmp_dir!()
      flag = Path.join(dir, "healthy")
      backend = start_backend!(args: ["exit_unless_file", flag])
      await_status(backend, &(&1.status == :failed))

      File.write!(flag, "")
      assert :ok = Backend.restart(backend)

      snapshot = await_ready(backend)
      assert snapshot.failures == 0
      assert snapshot.last_error == nil
    end

    test "a start-up timeout counts as a failure" do
      backend = start_backend!(args: ["never_start"], startup_timeout_ms: 100)

      snapshot = await_status(backend, &(&1.status == :failed))

      assert snapshot.last_error == :startup_timeout
    end

    test "ready workers are kept when a replacement cannot start" do
      dir = QueueFixture.tmp_dir!()
      flag = Path.join(dir, "healthy")
      File.write!(flag, "")
      backend = start_backend!(args: ["exit_unless_file", flag])
      first = await_ready(backend)

      File.rm!(flag)
      victim = hd(first.workers)
      {_output, 0} = System.cmd("kill", ["-KILL", Integer.to_string(victim.os_pid)])

      snapshot = await_status(backend, &(&1.failures >= 3))

      assert snapshot.status == :degraded
      assert snapshot.ready == 2
      assert pids(snapshot) == tl(pids(first))
      assert {:ok, _worker} = Backend.checkout(backend)
    end
  end
end
