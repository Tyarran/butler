defmodule ButlerWeb.MCPController do
  @moduledoc """
  HTTP face of the MCP proxy: the MCP "Streamable HTTP" transport, without
  server-sent events.

    * `POST /mcp/:backend` - one JSON-RPC message in, one JSON message out
      (`200`), or `202` for a notification or a response
    * `DELETE /mcp/:backend` - ends the session (`Mcp-Session-Id` header)
    * `GET /mcp/:backend` - `405`, the proxy never streams

  `:backend` is `full` or `light`. All the logic lives in `Butler.MCP`.
  """
  use ButlerWeb, :controller

  alias Butler.MCP
  alias Butler.MCP.Protocol

  @session_header "mcp-session-id"
  @backends %{"full" => :full, "light" => :light}

  @doc "Relays one JSON-RPC message."
  def post(conn, %{"backend" => backend}) do
    with_backend(conn, backend, fn backend ->
      respond(conn, MCP.handle(backend, session_id(conn), conn.body_params))
    end)
  end

  @doc "Ends a client session."
  def delete(conn, %{"backend" => backend}) do
    with_backend(conn, backend, fn backend ->
      case MCP.close_session(backend, session_id(conn)) do
        :ok -> send_resp(conn, 204, "")
        :unknown_session -> respond(conn, :unknown_session)
      end
    end)
  end

  @doc "The proxy has no server-to-client stream."
  def stream(conn, _params) do
    conn
    |> put_resp_header("allow", "POST, DELETE")
    |> put_status(405)
    |> json(Protocol.error(nil, -32_601, "Method not allowed"))
  end

  defp with_backend(conn, backend, fun) do
    case Map.fetch(@backends, backend) do
      {:ok, backend} -> fun.(backend)
      :error -> conn |> put_status(404) |> json(%{error: "Unknown backend"})
    end
  end

  defp session_id(conn) do
    case get_req_header(conn, @session_header) do
      [id | _rest] -> id
      [] -> nil
    end
  end

  defp respond(conn, {:json, message}), do: json(conn, message)

  defp respond(conn, {:json, message, session_id}) do
    conn |> put_resp_header(@session_header, session_id) |> json(message)
  end

  defp respond(conn, :accepted), do: send_resp(conn, 202, "")

  defp respond(conn, {:bad_request, message}), do: conn |> put_status(400) |> json(message)

  defp respond(conn, :unknown_session) do
    conn |> put_status(404) |> json(Protocol.error(nil, -32_001, "Session not found"))
  end

  defp respond(conn, :unavailable) do
    conn |> put_status(503) |> json(Protocol.error(nil, -32_603, "MCP proxy is disabled"))
  end
end
