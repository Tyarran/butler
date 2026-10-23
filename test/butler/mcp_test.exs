defmodule Butler.MCPTest do
  # The subsystem registers global names: no concurrency.
  use ExUnit.Case, async: false

  alias Butler.Maintenance
  alias Butler.MCP
  alias Butler.MCP.BackendSupervisor
  alias Butler.MCP.Sessions

  @fake Path.expand("../support/fake_mcp.sh", __DIR__)

  setup do
    previous = Application.fetch_env(:butler, :mcp)

    Application.put_env(:butler, :mcp,
      idle_rotation_ms: 60_000,
      pool_size: 2,
      startup_timeout_ms: 5_000,
      backends: %{full: [bin: @fake], light: [bin: @fake]}
    )

    on_exit(fn ->
      Maintenance.leave()

      case previous do
        {:ok, value} -> Application.put_env(:butler, :mcp, value)
        :error -> Application.delete_env(:butler, :mcp)
      end
    end)

    :ok
  end

  defp start_mcp! do
    start_supervised!(Butler.MCP.Supervisor)
    MCP.subscribe()
    :ok
  end

  defp request(method, id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => method}

  defp initialize!(backend) do
    assert {:json, %{"id" => 1, "result" => %{"serverInfo" => _info}}, session} =
             MCP.handle(backend, nil, request("initialize", 1))

    session
  end

  defp await_all_ready do
    case MCP.status() do
      [] ->
        flunk("not running")

      list ->
        if Enum.all?(list, &(&1.status == :ready)) do
          list
        else
          receive do
            {:mcp_changed, _backend} -> await_all_ready()
          after
            5_000 -> flunk("backends never ready: #{inspect(list)}")
          end
        end
    end
  end

  test "is unavailable while the subsystem is not running" do
    refute MCP.running?()
    assert MCP.handle(:light, nil, request("initialize", 1)) == :unavailable
    assert MCP.status() == []
    assert MCP.restart(:light) == {:error, :unavailable}
  end

  test "initialize creates a session and is answered from the warm-up handshake" do
    start_mcp!()

    session = initialize!(:light)

    assert is_binary(session)
    assert Sessions.validate(session, :light) == :ok
    assert Sessions.validate(session, :full) == :error
  end

  test "requests are forwarded and keep the client id" do
    start_mcp!()
    session = initialize!(:light)

    assert {:json, %{"id" => "abc", "result" => %{"method" => "tools/list"}}} =
             MCP.handle(:light, session, request("tools/list", "abc"))
  end

  test "both backends are served independently" do
    start_mcp!()
    light = initialize!(:light)
    full = initialize!(:full)

    assert {:json, %{"result" => %{"pid" => light_pid}}} =
             MCP.handle(:light, light, request("ping", 1))

    assert {:json, %{"result" => %{"pid" => full_pid}}} =
             MCP.handle(:full, full, request("ping", 1))

    assert light_pid != full_pid
    assert MCP.handle(:full, light, request("ping", 1)) == :unknown_session
  end

  test "a request needs a session" do
    start_mcp!()

    assert {:bad_request, %{"id" => 5, "error" => %{"code" => -32_600}}} =
             MCP.handle(:light, nil, request("ping", 5))

    assert MCP.handle(:light, "nope", request("ping", 5)) == :unknown_session
  end

  test "notifications and responses are acknowledged and dropped" do
    start_mcp!()
    session = initialize!(:light)

    notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
    response = %{"jsonrpc" => "2.0", "id" => 9, "result" => %{}}

    assert MCP.handle(:light, session, notification) == :accepted
    assert MCP.handle(:light, session, response) == :accepted
    assert MCP.handle(:light, nil, notification) |> elem(0) == :bad_request
  end

  test "batches and malformed messages are bad requests" do
    start_mcp!()

    assert {:bad_request, %{"error" => %{"code" => -32_600}}} =
             MCP.handle(:light, nil, %{"_json" => [request("ping", 1)]})

    assert {:bad_request, %{"id" => 3, "error" => _error}} =
             MCP.handle(:light, nil, %{"jsonrpc" => "1.0", "id" => 3, "method" => "x"})
  end

  test "a backend crash is an immediate error, and the session survives" do
    start_mcp!()
    session = initialize!(:light)

    assert {:json, %{"id" => 2, "error" => %{"code" => -32_603, "message" => message}}} =
             MCP.handle(:light, session, request("crash", 2))

    assert message =~ "exited"

    assert {:json, %{"result" => %{"method" => "ping"}}} =
             MCP.handle(:light, session, request("ping", 3))

    assert %{errors: 1} = Enum.find(MCP.status(), &(&1.id == :light))
  end

  test "status/0 reports each backend with its sessions and requests" do
    start_mcp!()
    session = initialize!(:light)
    MCP.handle(:light, session, request("ping", 2))
    await_all_ready()

    assert [%{id: :full, sessions: 0}, %{id: :light, sessions: 1, requests: 2}] = MCP.status()
  end

  test "close_session/2 ends a session" do
    start_mcp!()
    session = initialize!(:light)

    assert MCP.close_session(:light, session) == :ok
    assert MCP.handle(:light, session, request("ping", 2)) == :unknown_session
    assert MCP.close_session(:light, session) == :unknown_session
  end

  test "restart/1 rotates a backend" do
    start_mcp!()
    [_full, light] = await_all_ready()

    assert MCP.restart(:light) == :ok

    new_light = Enum.find(MCP.status(), &(&1.id == :light))
    assert new_light.rotations == 1

    assert Enum.all?(
             new_light.workers,
             &(&1.pid not in Enum.map(light.workers, fn w -> w.pid end))
           )
  end

  test "a backend that cannot start is reported as an error to the client" do
    Application.put_env(:butler, :mcp,
      max_start_failures: 1,
      backends: %{full: [bin: @fake], light: [bin: "/nonexistent/butler-test/nope"]}
    )

    start_mcp!()

    assert {:json, %{"id" => 1, "error" => %{"message" => message}}} =
             MCP.handle(:light, nil, request("initialize", 1))

    assert message =~ "failed to start"
    assert [_full, %{status: :failed}] = MCP.status()
  end

  defp call_tool(name), do: Map.put(request("tools/call", 7), "params", %{"name" => name})

  defp requests(backend), do: Enum.find(MCP.status(), &(&1.id == backend)).requests

  describe "maintenance gating" do
    test "every request is refused at once and never reaches a worker" do
      start_mcp!()
      session = initialize!(:light)
      await_all_ready()
      before = requests(:light)

      Maintenance.enter("job")

      for backend <- [:light, :full], message <- [request("initialize", 1), request("ping", 2)] do
        assert {:json, %{"id" => id, "error" => %{"code" => -32_001, "message" => text}}} =
                 MCP.handle(backend, session, message)

        assert id == message["id"]
        assert text == "Maintenance in progress, retry later"
      end

      # no session needed, and even a request that would crash the worker
      assert {:json, %{"error" => %{"code" => -32_001}}} =
               MCP.handle(:light, nil, request("crash", 3))

      assert {:json, %{"error" => %{"code" => -32_001}}} =
               MCP.handle(:light, session, call_tool("mempalace_search"))

      assert requests(:light) == before
      assert Enum.find(MCP.status(), &(&1.id == :light)).errors == 0
    end

    test "notifications are still acknowledged" do
      start_mcp!()
      session = initialize!(:light)
      Maintenance.enter("job")

      notification = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      assert MCP.handle(:light, session, notification) == :accepted
    end

    test "requests flow again once maintenance is left" do
      start_mcp!()
      session = initialize!(:light)
      Maintenance.enter("job")
      Maintenance.leave()

      assert {:json, %{"result" => %{"method" => "ping"}}} =
               MCP.handle(:light, session, request("ping", 2))
    end
  end

  describe "read allowlist" do
    test "read tools are forwarded" do
      start_mcp!()
      session = initialize!(:light)

      assert {:json, %{"id" => 7, "result" => %{"content" => [%{"text" => text}]}}} =
               MCP.handle(:light, session, call_tool("mempalace_search"))

      assert text =~ "mempalace_search"
    end

    test "write, maintenance and unknown tools are refused without reaching a worker" do
      start_mcp!()
      session = initialize!(:light)
      await_all_ready()
      before = requests(:light)

      names =
        ["mempalace_add_drawer", "mempalace_diary_write", "mempalace_kg_supersede"] ++
          ["mempalace_mine", "mempalace_reconnect", "nope", "", nil, 42, %{"x" => 1}]

      for name <- names do
        assert {:json, %{"id" => 7, "error" => %{"message" => message}}} =
                 MCP.handle(:light, session, call_tool(name))

        assert message == "write tools must be submitted through the Butler API"
      end

      no_name = Map.put(request("tools/call", 8), "params", %{})

      assert {:json, %{"error" => %{"message" => "write tools" <> _}}} =
               MCP.handle(:light, session, no_name)

      assert requests(:light) == before
    end

    test "other methods are not filtered" do
      start_mcp!()
      session = initialize!(:light)

      assert {:json, %{"result" => %{"method" => "tools/list"}}} =
               MCP.handle(:light, session, request("tools/list", 4))
    end
  end

  describe "suspend/0, resume/0 and drain/1" do
    defp live_os_pids do
      for %{workers: workers} <- MCP.status(), worker <- workers, do: worker.os_pid
    end

    defp worker_children do
      for backend <- [:full, :light],
          do: DynamicSupervisor.count_children(BackendSupervisor.workers_name(backend)).active
    end

    test "suspend stops every worker and OS process, resume starts fresh ones" do
      start_mcp!()
      session = initialize!(:light)
      await_all_ready()
      os_pids = live_os_pids()
      assert length(os_pids) == 4

      assert MCP.suspend() == :ok

      assert Enum.all?(MCP.status(), &(&1.status == :suspended and &1.workers == []))
      assert worker_children() == [0, 0]
      assert Enum.all?(os_pids, &(not File.exists?("/proc/#{&1}")))

      # idempotent
      assert MCP.suspend() == :ok

      assert MCP.resume() == :ok
      assert MCP.resume() == :ok
      await_all_ready()

      assert {:json, %{"result" => %{"pid" => pid}}} =
               MCP.handle(:light, session, request("ping", 2))

      refute pid in os_pids
    end

    test "a checkout while suspended fails at once" do
      start_mcp!()
      session = initialize!(:light)
      await_all_ready()
      MCP.suspend()

      assert {:json, %{"error" => %{"message" => "Maintenance in progress, retry later"}}} =
               MCP.handle(:light, session, request("ping", 2))
    end

    test "drain returns :ok when nothing is in flight" do
      start_mcp!()
      await_all_ready()
      assert MCP.drain(1_000) == :ok
    end

    test "drain waits for a request in flight, and times out when it hangs" do
      start_mcp!()
      session = initialize!(:light)
      await_all_ready()

      task = Task.async(fn -> MCP.handle(:light, session, request("hang", 5)) end)
      await_pending(:light)

      assert MCP.drain(100) == :timeout

      # suspending cuts the hung request
      MCP.suspend()
      assert {:json, %{"error" => _error}} = Task.await(task, 5_000)
    end

    test "drain is a no-op while the proxy is not running" do
      assert MCP.drain(10) == :ok
      assert MCP.suspend() == :ok
      assert MCP.resume() == :ok
    end

    # Round-robin: any worker of the backend may hold the request.
    defp await_pending(backend, tries \\ 100_000) do
      %{workers: workers} = Enum.find(MCP.status(), &(&1.id == backend))

      cond do
        Enum.any?(workers, &(&1.pending > 0)) -> :ok
        tries == 0 -> flunk("request never became pending")
        true -> await_pending(backend, tries - 1)
      end
    end
  end
end
