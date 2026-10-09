defmodule ButlerWeb.Plugs.PreParserGate do
  @moduledoc """
  Runs the access checks of the machine-facing routes **before**
  `Plug.Parsers`, so an unauthenticated or non-loopback caller can never make
  Butler read and parse a request body (up to 1 MB).

    * `/api/*`: `ButlerWeb.Plugs.LoopbackGuard`, then `ButlerWeb.Plugs.APIAuth`;
    * `/mcp/:backend`: `ButlerWeb.Plugs.LoopbackGuard`.

  Other paths (the dashboard, LiveView) pass through untouched. The router
  pipelines run the same plugs again, which is harmless and keeps each
  pipeline safe on its own.
  """

  @behaviour Plug

  alias ButlerWeb.Plugs.APIAuth
  alias ButlerWeb.Plugs.LoopbackGuard

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(%Plug.Conn{path_info: ["api" | _rest]} = conn, opts) do
    conn = LoopbackGuard.call(conn, opts)
    if conn.halted, do: conn, else: APIAuth.call(conn, opts)
  end

  # `/mcp` alone is the dashboard page; the proxy lives under `/mcp/:backend`.
  def call(%Plug.Conn{path_info: ["mcp", _backend | _rest]} = conn, opts),
    do: LoopbackGuard.call(conn, opts)

  def call(conn, _opts), do: conn
end
