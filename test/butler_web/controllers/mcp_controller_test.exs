defmodule ButlerWeb.MCPControllerTest do
  # The MCP subsystem registers global names: no concurrency.
  use ButlerWeb.ConnCase, async: false

  @fake Path.expand("../../support/fake_mcp.sh", __DIR__)

  setup %{conn: conn} do
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

    start_supervised!(Butler.MCP.Supervisor)

    {:ok, conn: %{conn | host: "localhost"}}
  end

  defp rpc(conn, backend, message, opts \\ []) do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("accept", "application/json, text/event-stream")

    conn =
      case Keyword.get(opts, :session) do
        nil -> conn
        session -> put_req_header(conn, "mcp-session-id", session)
      end

    post(conn, "/mcp/#{backend}", Jason.encode!(message))
  end

  defp request(method, id), do: %{"jsonrpc" => "2.0", "id" => id, "method" => method}

  defp initialize!(conn, backend \\ "light") do
    conn = rpc(conn, backend, request("initialize", 1))
    assert %{"result" => %{"serverInfo" => _info}} = json_response(conn, 200)
    assert [session] = get_resp_header(conn, "mcp-session-id")
    session
  end

  describe "POST" do
    test "initialize returns the backend handshake and a session id", %{conn: conn} do
      conn = rpc(conn, "light", request("initialize", 1))

      assert %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"protocolVersion" => _version}} =
               json_response(conn, 200)

      assert [session] = get_resp_header(conn, "mcp-session-id")
      assert session != ""
    end

    test "relays a request with its session", %{conn: conn} do
      session = initialize!(conn)

      conn = rpc(conn, "light", request("tools/list", "abc"), session: session)

      assert %{"id" => "abc", "result" => %{"method" => "tools/list"}} = json_response(conn, 200)
    end

    test "serves the full backend too", %{conn: conn} do
      session = initialize!(conn, "full")
      conn = rpc(conn, "full", request("ping", 2), session: session)
      assert %{"result" => %{"method" => "ping"}} = json_response(conn, 200)
    end

    test "acknowledges notifications with 202", %{conn: conn} do
      session = initialize!(conn)
      message = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

      conn = rpc(conn, "light", message, session: session)

      assert response(conn, 202) == ""
    end

    test "a request without a session is a 400", %{conn: conn} do
      conn = rpc(conn, "light", request("ping", 5))
      assert %{"id" => 5, "error" => %{"code" => -32_600}} = json_response(conn, 400)
    end

    test "an unknown session is a 404", %{conn: conn} do
      conn = rpc(conn, "light", request("ping", 5), session: "nope")
      assert %{"error" => %{"message" => "Session not found"}} = json_response(conn, 404)
    end

    test "a session is bound to its backend", %{conn: conn} do
      session = initialize!(conn, "light")
      conn = rpc(conn, "full", request("ping", 5), session: session)
      assert json_response(conn, 404)
    end

    test "a batch is a 400", %{conn: conn} do
      conn = rpc(conn, "light", [request("ping", 1), request("ping", 2)])
      assert %{"error" => %{"code" => -32_600}} = json_response(conn, 400)
    end

    test "a malformed message is a 400", %{conn: conn} do
      conn = rpc(conn, "light", %{"hello" => "world"})
      assert %{"error" => %{"code" => -32_600}} = json_response(conn, 400)
    end

    test "invalid JSON is a 400", %{conn: conn} do
      assert_error_sent 400, fn ->
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/mcp/light", "{not json")
      end
    end

    test "a backend failure is a JSON-RPC error and keeps the session", %{conn: conn} do
      session = initialize!(conn)

      crashed = rpc(conn, "light", request("crash", 2), session: session)
      assert %{"id" => 2, "error" => %{"code" => -32_603}} = json_response(crashed, 200)

      alive = rpc(conn, "light", request("ping", 3), session: session)
      assert %{"result" => %{"method" => "ping"}} = json_response(alive, 200)
    end

    test "an unknown backend is a 404", %{conn: conn} do
      conn = rpc(conn, "other", request("initialize", 1))
      assert json_response(conn, 404)
    end
  end

  test "answers 503 when the proxy is disabled", %{conn: conn} do
    :ok = stop_supervised(Butler.MCP.Supervisor)

    conn = rpc(conn, "light", request("initialize", 1))

    assert %{"error" => %{"code" => -32_603}} = json_response(conn, 503)
  end

  describe "GET and DELETE" do
    test "GET is not allowed: the proxy never streams", %{conn: conn} do
      conn = get(conn, "/mcp/light")

      assert json_response(conn, 405)
      assert get_resp_header(conn, "allow") == ["POST, DELETE"]
    end

    test "DELETE ends the session", %{conn: conn} do
      session = initialize!(conn)

      deleted = conn |> put_req_header("mcp-session-id", session) |> delete("/mcp/light")
      assert response(deleted, 204) == ""

      conn = rpc(conn, "light", request("ping", 2), session: session)
      assert json_response(conn, 404)
    end

    test "DELETE of an unknown session is a 404", %{conn: conn} do
      conn = conn |> put_req_header("mcp-session-id", "nope") |> delete("/mcp/light")
      assert json_response(conn, 404)
    end
  end

  describe "access guard" do
    test "accepts loopback hosts, with any port", %{conn: conn} do
      for host <- ["localhost", "127.0.0.1", "::1", "[::1]"] do
        assert %{status: 200} = rpc(%{conn | host: host}, "light", request("initialize", 1))
      end
    end

    test "rejects a foreign Host (DNS rebinding)", %{conn: conn} do
      conn = rpc(%{conn | host: "evil.example.com"}, "light", request("initialize", 1))
      assert json_response(conn, 403)
    end

    test "rejects a non-loopback peer", %{conn: conn} do
      conn = rpc(%{conn | remote_ip: {192, 168, 1, 20}}, "light", request("initialize", 1))
      assert json_response(conn, 403)
    end

    test "accepts IPv6 and IPv4-mapped loopback peers", %{conn: conn} do
      for ip <- [{0, 0, 0, 0, 0, 0, 0, 1}, {0, 0, 0, 0, 0, 65_535, 0x7F00, 1}] do
        assert %{status: 200} = rpc(%{conn | remote_ip: ip}, "light", request("initialize", 1))
      end
    end

    test "rejects a foreign mapped IPv4 peer", %{conn: conn} do
      conn =
        rpc(
          %{conn | remote_ip: {0, 0, 0, 0, 0, 65_535, 0xC0A8, 1}},
          "light",
          request("initialize", 1)
        )

      assert json_response(conn, 403)
    end

    test "accepts a loopback Origin and an absent Origin", %{conn: conn} do
      for origin <- ["http://localhost:4000", "http://127.0.0.1:4000", "http://[::1]:4000"] do
        conn = put_req_header(conn, "origin", origin)
        assert %{status: 200} = rpc(conn, "light", request("initialize", 1))
      end

      assert %{status: 200} = rpc(conn, "light", request("initialize", 1))
    end

    test "rejects a foreign or opaque Origin", %{conn: conn} do
      for origin <- ["https://evil.example.com", "null", "http://localhost.evil.com", "file://"] do
        conn = put_req_header(conn, "origin", origin)
        assert json_response(rpc(conn, "light", request("initialize", 1)), 403)
      end
    end

    test "guards GET and DELETE as well", %{conn: conn} do
      conn = put_req_header(conn, "origin", "https://evil.example.com")
      assert json_response(get(conn, "/mcp/light"), 403)
      assert json_response(delete(conn, "/mcp/light"), 403)
    end
  end
end
