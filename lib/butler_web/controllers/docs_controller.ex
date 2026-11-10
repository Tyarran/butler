defmodule ButlerWeb.DocsController do
  @moduledoc """
  The interactive API documentation (`GET /swaggerui`).

  A same-origin Swagger UI that renders the document served at `/openapi`.
  Like `/openapi` it is loopback only and needs no token: the API calls made
  from it (`Try it out`) still need the Bearer token, entered with
  `Authorize`.
  """
  use ButlerWeb, :controller

  # The page has its own root layout: it loads the Swagger UI bundle and style
  # only, not the dashboard's `app.js` / `app.css`.
  plug :put_root_layout, html: {ButlerWeb.Layouts, :docs}
  plug :put_layout, false

  @doc "Renders the Swagger UI page."
  def swagger(conn, _params), do: render(conn, :swagger)
end
