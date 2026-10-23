defmodule ButlerWeb.API.Schemas.HealthResponse do
  @moduledoc "Answer of `GET /api/v1/health`: 200, or 503 with `ok: false`."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  @counts ~w(queued running succeeded failed cancelled)

  OpenApiSpex.schema(
    %{
      title: "HealthResponse",
      type: :object,
      required: [:ok, :worker, :maintenance],
      properties: %{
        ok: %Schema{type: :boolean},
        worker: %Schema{
          type: :string,
          enum: ~w(idle running blocked booting unavailable),
          description: "`blocked` while the legacy Python daemon is alive."
        },
        active_job_id: %Schema{type: :string, nullable: true},
        maintenance: %Schema{type: :boolean},
        counts: %Schema{
          type: :object,
          nullable: true,
          properties: Map.new(@counts, &{String.to_atom(&1), %Schema{type: :integer}})
        }
      }
    },
    struct?: false
  )
end
