defmodule Butler.MCPTest do
  # The subsystem registers global names: no concurrency.
  use ExUnit.Case, async: false

  alias Butler.MCP
  alias Butler.MCP.Sessions

  @fake Path.expand("../support/fake_mcp.sh", __DIR__)

  setup do
    previous = Application.fetch_env(:butler, :mcp)

    Application.put_env(:butler, :mcp,
      idle_rotation_ms: 60_000,
      startup_timeout_ms: 5_000,
      backends: %{full: [bin: @fake], light: [bin: @fake]}
    )

    on_exit(fn ->
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
    assert new_light.rotations == 1 or new_light.active.pid == light.standby.pid
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
end
