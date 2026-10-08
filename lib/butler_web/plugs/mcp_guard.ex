defmodule ButlerWeb.Plugs.MCPGuard do
  @moduledoc """
  Guards the MCP proxy routes, which have no authentication.

  Three checks protect against other machines and against web pages that
  aim at `localhost` (cross-origin requests, DNS rebinding). A request failing
  any of them gets a `403` and is halted:

    * the peer address must be a loopback address;
    * the `Host` must be `localhost`, `127.0.0.1` or `::1` (any port), which
      defeats DNS rebinding;
    * the `Origin`, when there is one, must be a loopback host too (any
      port). Requests without `Origin` come from non-browser clients and
      are accepted.
  """

  @behaviour Plug

  import Plug.Conn

  @loopback_hosts ["localhost", "127.0.0.1", "::1"]

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    if loopback_peer?(conn.remote_ip) and loopback_host?(conn.host) and allowed_origin?(conn) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{error: "Forbidden"}))
      |> halt()
    end
  end

  defp loopback_peer?({127, _b, _c, _d}), do: true
  defp loopback_peer?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  # IPv4-mapped IPv6 address of a 127.x.x.x peer (::ffff:127.x.x.x).
  defp loopback_peer?({0, 0, 0, 0, 0, 65_535, high, _low}), do: div(high, 256) == 127
  defp loopback_peer?(_other), do: false

  defp loopback_host?(host) when is_binary(host) do
    host |> String.trim_leading("[") |> String.trim_trailing("]") |> Kernel.in(@loopback_hosts)
  end

  defp loopback_host?(_host), do: false

  defp allowed_origin?(conn) do
    case get_req_header(conn, "origin") do
      [] -> true
      [origin] -> origin_host_allowed?(origin)
      _several -> false
    end
  end

  defp origin_host_allowed?(origin) do
    case URI.parse(origin) do
      %URI{scheme: scheme, host: host} when scheme in ["http", "https"] ->
        loopback_host?(host)

      _other ->
        false
    end
  end
end
