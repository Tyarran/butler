defmodule ButlerWeb.Plugs.APIAuth do
  @moduledoc """
  Bearer-token authentication of the job API.

  The token is Butler's own (`Butler.Token`, created with mode 600 in the
  state directory) and is compared in constant time with
  `Plug.Crypto.secure_compare/2`. A missing, malformed or wrong token, or a
  token that cannot be read, answers `401 unauthorized` and halts. Run it
  after `ButlerWeb.Plugs.LoopbackGuard`.
  """

  @behaviour Plug

  import Plug.Conn

  alias Butler.Token
  alias ButlerWeb.APIError

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    with {:ok, presented} <- bearer(conn),
         {:ok, expected} <- Token.ensure(),
         true <- Token.valid?(presented, expected) do
      conn
    else
      _failure ->
        conn
        |> put_resp_header("www-authenticate", "Bearer")
        |> APIError.halt(401, "unauthorized", "A valid Bearer token is required")
    end
  end

  defp bearer(conn) do
    case get_req_header(conn, "authorization") do
      [header] -> parse(header)
      _other -> :error
    end
  end

  defp parse(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] when token != "" ->
        if String.downcase(scheme) == "bearer", do: {:ok, String.trim(token)}, else: :error

      _other ->
        :error
    end
  end
end
