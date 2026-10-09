defmodule ButlerWeb.Plugs.LoopbackGuardTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias ButlerWeb.Plugs.LoopbackGuard

  defp call(host \\ "localhost", ip \\ {127, 0, 0, 1}, origin \\ nil) do
    conn = %{conn(:get, "/") | host: host, remote_ip: ip}
    conn = if origin, do: Plug.Conn.put_req_header(conn, "origin", origin), else: conn
    LoopbackGuard.call(conn, [])
  end

  test "lets loopback peers, hosts and origins through" do
    refute call().halted
    refute call("127.0.0.1", {0, 0, 0, 0, 0, 0, 0, 1}, "http://localhost:3000").halted
  end

  test "refuses a foreign peer, host or origin with the API error shape" do
    for conn <- [
          call("localhost", {10, 0, 0, 1}),
          call("evil.test"),
          call("localhost", {127, 0, 0, 1}, "https://evil.test")
        ] do
      assert conn.halted
      assert conn.status == 403
      assert %{"error" => %{"code" => "forbidden"}} = Jason.decode!(conn.resp_body)
    end
  end
end
