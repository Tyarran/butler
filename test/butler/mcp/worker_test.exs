defmodule Butler.MCP.WorkerTest do
  use ExUnit.Case, async: true

  alias Butler.MCP.Worker

  @fake Path.expand("../../support/fake_mcp.sh", __DIR__)

  defp start!(args, opts \\ []) do
    opts = Keyword.merge([bin: @fake, args: args, owner: self()], opts)
    {:ok, worker} = Worker.start_link(opts)
    worker
  end

  defp start_ready!(opts \\ []) do
    worker = start!([], opts)
    assert_receive {:mcp_worker, ^worker, :ready}, 5_000
    worker
  end

  defp request(method, id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => method}

  # Polls /proc: there is no message to wait for when an OS process dies.
  defp wait_dead(os_pid, tries \\ 200) do
    cond do
      not File.exists?("/proc/#{os_pid}") ->
        :ok

      tries == 0 ->
        flunk("OS process #{os_pid} is still alive")

      true ->
        receive do
        after
          10 -> wait_dead(os_pid, tries - 1)
        end
    end
  end

  describe "start-up" do
    test "completes the handshake and notifies the owner" do
      worker = start_ready!()

      assert %{phase: :ready, os_pid: os_pid, pending: 0} = Worker.info(worker)
      assert is_integer(os_pid)
      assert {:ok, %{"serverInfo" => %{"name" => "fake-mcp"}}} = Worker.initialize_result(worker)
    end

    test "reports a missing executable" do
      worker = start!([], bin: "/nonexistent/butler-test/nope")

      assert_receive {:mcp_worker, ^worker,
                      {:exited, :starting,
                       {:executable_not_found, "/nonexistent/butler-test/nope"}}}
    end

    test "reports a process that exits before the handshake" do
      worker = start!(["exit_on_start"])
      assert_receive {:mcp_worker, ^worker, {:exited, :starting, {:exit_status, 3}}}, 5_000
    end

    test "reports a start-up timeout and kills the process" do
      worker = start!(["never_start"], startup_timeout_ms: 100)
      %{os_pid: os_pid} = Worker.info(worker)

      assert_receive {:mcp_worker, ^worker, {:exited, :starting, :startup_timeout}}, 5_000
      wait_dead(os_pid)
    end

    test "refuses requests until ready" do
      worker = start!(["never_start"], startup_timeout_ms: 5_000)
      assert Worker.call(worker, request("ping", 1)) == {:error, :not_ready}
      Worker.stop(worker)
    end
  end

  describe "requests" do
    test "answers keep the id chosen by the client" do
      worker = start_ready!()

      assert {:ok, %{"id" => "client-9", "result" => %{"method" => "ping"}}} =
               Worker.call(worker, request("ping", "client-9"))
    end

    test "concurrent requests are multiplexed on one process" do
      worker = start_ready!()

      slow = Task.async(fn -> Worker.call(worker, request("slow", "a")) end)
      fast = Worker.call(worker, request("ping", "b"))

      assert {:ok, %{"id" => "b", "result" => %{"method" => "ping"}}} = fast
      assert {:ok, %{"id" => "a", "result" => %{"method" => "slow"}}} = Task.await(slow)
    end

    test "the same client id can be used by several requests at once" do
      worker = start_ready!()

      tasks = for _i <- 1..5, do: Task.async(fn -> Worker.call(worker, request("slow", 1)) end)

      for task <- tasks do
        assert {:ok, %{"id" => 1, "result" => %{"method" => "slow"}}} = Task.await(task)
      end
    end

    test "very large answers are reassembled" do
      worker = start_ready!()

      assert {:ok, %{"result" => %{"data" => data}}} = Worker.call(worker, request("big", 1))
      assert byte_size(data) == 200_000
    end

    test "non-JSON lines from the backend are ignored" do
      worker = start_ready!()

      assert {:ok, %{"result" => %{"method" => "noisy"}}} =
               Worker.call(worker, request("noisy", 1))
    end

    test "notifications are forwarded without an answer" do
      worker = start_ready!()
      assert :ok = Worker.notify(worker, %{"jsonrpc" => "2.0", "method" => "notifications/x"})
      assert {:ok, _answer} = Worker.call(worker, request("ping", 1))
    end

    test "a slow request times out without killing the worker" do
      worker = start_ready!(request_timeout_ms: 100)

      assert Worker.call(worker, request("hang", 1)) == {:error, :timeout}
      assert %{phase: :ready, pending: 0} = Worker.info(worker)
      assert {:ok, _answer} = Worker.call(worker, request("ping", 2))
    end
  end

  describe "crash" do
    test "in-flight requests fail immediately and the owner is notified" do
      worker = start_ready!()

      hanging = Task.async(fn -> Worker.call(worker, request("hang", 1)) end)
      assert {:error, {:backend_exited, 1}} = Worker.call(worker, request("crash", 2))
      assert {:error, {:backend_exited, 1}} = Task.await(hanging)

      assert_receive {:mcp_worker, ^worker, {:exited, :ready, {:exit_status, 1}}}
    end

    test "the worker stops after the crash" do
      worker = start_ready!()
      ref = Process.monitor(worker)

      Worker.call(worker, request("crash", 1))

      assert_receive {:DOWN, ^ref, :process, ^worker, :normal}
      assert Worker.call(worker, request("ping", 2)) == {:error, :worker_unavailable}
    end
  end

  describe "stop" do
    test "kills the OS process and sends no event" do
      worker = start_ready!()
      %{os_pid: os_pid} = Worker.info(worker)

      assert :ok = Worker.stop(worker)

      wait_dead(os_pid)
      refute_received {:mcp_worker, ^worker, _event}
    end

    test "fails the requests still in flight" do
      worker = start_ready!()
      hanging = Task.async(fn -> Worker.call(worker, request("hang", 1)) end)
      _ = Worker.info(worker)

      Worker.stop(worker)

      assert Task.await(hanging) == {:error, :worker_stopped}
    end

    test "stops when its owner dies, and kills the OS process" do
      supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})
      owner = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, worker} =
        DynamicSupervisor.start_child(supervisor, {Worker, bin: @fake, owner: owner})

      ref = Process.monitor(worker)
      os_pid = wait_ready_pid(worker)

      Process.exit(owner, :kill)

      assert_receive {:DOWN, ^ref, :process, ^worker, :normal}, 5_000
      wait_dead(os_pid)
    end
  end

  defp wait_ready_pid(worker, tries \\ 200) do
    case Worker.info(worker) do
      %{phase: :ready, os_pid: os_pid} ->
        os_pid

      _starting when tries > 0 ->
        receive do
        after
          10 -> wait_ready_pid(worker, tries - 1)
        end

      _starting ->
        flunk("worker never became ready")
    end
  end
end
