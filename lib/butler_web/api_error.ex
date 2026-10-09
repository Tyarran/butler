defmodule ButlerWeb.APIError do
  @moduledoc """
  The error body of the HTTP API: `{"error": {"code", "message", "field"?}}`.

  Shared by the API controllers and plugs; `field` is only present for
  payload errors that point at a key.
  """

  import Phoenix.Controller, only: [json: 2]
  import Plug.Conn

  @doc "The JSON-encodable error body."
  @spec body(String.t(), String.t(), String.t() | nil) :: map()
  def body(code, message, field \\ nil) do
    error = %{code: code, message: message}
    %{error: if(field, do: Map.put(error, :field, field), else: error)}
  end

  @doc "Sends the error with `status`."
  @spec render(Plug.Conn.t(), pos_integer(), String.t(), String.t(), String.t() | nil) ::
          Plug.Conn.t()
  def render(conn, status, code, message, field \\ nil) do
    conn |> put_status(status) |> json(body(code, message, field))
  end

  @doc "Like `render/5`, and halts the connection (for plugs)."
  @spec halt(Plug.Conn.t(), pos_integer(), String.t(), String.t(), String.t() | nil) ::
          Plug.Conn.t()
  def halt(conn, status, code, message, field \\ nil) do
    conn |> render(status, code, message, field) |> halt()
  end
end
