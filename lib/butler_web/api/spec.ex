defmodule ButlerWeb.API.Spec do
  @moduledoc """
  The OpenAPI 3 document of `/api/v1`, built from the operations declared in
  the controllers (`ButlerWeb.JobController`, `ButlerWeb.HealthController`)
  and the schemas in `ButlerWeb.API.Schemas.*`. Served at `GET /openapi`.
  """

  @behaviour OpenApiSpex.OpenApi

  alias OpenApiSpex.Components
  alias OpenApiSpex.Info
  alias OpenApiSpex.OpenApi
  alias OpenApiSpex.Paths
  alias OpenApiSpex.SecurityScheme
  alias OpenApiSpex.Server

  @impl OpenApiSpex.OpenApi
  def spec do
    %OpenApi{
      info: %Info{
        title: "Butler job API",
        description:
          "Asynchronous job API of Butler (loopback only, Bearer token). See docs/api.md.",
        version: to_string(Application.spec(:butler, :vsn))
      },
      servers: [%Server{url: "/"}],
      paths: Paths.from_router(ButlerWeb.Router),
      components: %Components{
        securitySchemes: %{"bearerAuth" => %SecurityScheme{type: "http", scheme: "bearer"}}
      },
      security: [%{"bearerAuth" => []}]
    }
    |> OpenApiSpex.resolve_schema_modules()
  end
end
