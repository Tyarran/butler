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
    test "starts an active worker and a warm standby" do
      backend = start_backend!()

      snapshot = await_ready(backend)

      assert %{pid: active, os_pid: active_pid} = snapshot.active
      assert %{pid: standby, os_pid: standby_pid} = snapshot.standby
      assert active != standby
      assert active_pid != standby_pid
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

  describe "rotation" do
    test "the standby takes over after the idle delay and a new standby starts" do
      backend = start_backend!(idle_rotation_ms: 300)
      first = await_ready(backend)

      second = await_status(backend, &(&1.rotations >= 1 and &1.status == :ready))

      assert second.active.pid == first.standby.pid
      assert second.standby.pid not in [first.active.pid, first.standby.pid]
      wait_dead(first.active.os_pid)
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

    test "restart rotates right away when a standby is ready" do
      backend = start_backend!()
      first = await_ready(backend)

      assert :ok = Backend.restart(backend)
      second = await_status(backend, &(&1.rotations == 1 and &1.status == :ready))

      assert second.active.pid == first.standby.pid
      wait_dead(first.active.os_pid)
    end
  end

  describe "crash" do
    test "the standby takes over when the active worker dies" do
      backend = start_backend!()
      first = await_ready(backend)
      {:ok, worker} = Backend.checkout(backend)

      assert {:error, {:backend_exited, 1}} = Worker.call(worker, request("crash"))

      second = await_status(backend, &(&1.active && &1.active.pid == first.standby.pid))
      assert second.rotations == 0
      assert {:ok, active} = Backend.checkout(backend)
      assert {:ok, _answer} = Worker.call(active, request("ping"))

      third = await_ready(backend)
      assert third.standby.pid != first.standby.pid
    end

    test "a dead standby is replaced" do
      backend = start_backend!()
      first = await_ready(backend)

      {_output, 0} = System.cmd("kill", ["-KILL", Integer.to_string(first.standby.os_pid)])

      second =
        await_status(backend, &(&1.status == :ready and &1.standby.pid != first.standby.pid))

      assert second.active.pid == first.active.pid
    end
  end

  describe "failure" do
    test "gives up after max_start_failures and reports the cause" do
      backend = start_backend!(args: ["exit_on_start"])

      snapshot = await_status(backend, &(&1.status == :failed))

      assert snapshot.failures >= 3
      assert snapshot.last_error == {:exit_status, 3}
      assert snapshot.active == nil
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

    test "an active worker is kept when its standby cannot start" do
      dir = QueueFixture.tmp_dir!()
      flag = Path.join(dir, "healthy")
      File.write!(flag, "")
      backend = start_backend!(args: ["exit_unless_file", flag])
      first = await_ready(backend)

      File.rm!(flag)
      {_output, 0} = System.cmd("kill", ["-KILL", Integer.to_string(first.standby.os_pid)])

      snapshot = await_status(backend, &(&1.failures >= 3))

      assert snapshot.status == :degraded
      assert snapshot.active.pid == first.active.pid
      assert {:ok, _worker} = Backend.checkout(backend)
    end
  end
end
