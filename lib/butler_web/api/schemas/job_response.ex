defmodule ButlerWeb.API.Schemas.JobResponse do
  @moduledoc """
  Answer of `GET /api/v1/jobs/:id`. The `payload` (verbatim content) is only
  present with `?include_payload=true`.
  """

  require OpenApiSpex

  alias OpenApiSpex.Schema

  @states ~w(queued running succeeded failed cancelled unknown)

  OpenApiSpex.schema(
    %{
      title: "JobResponse",
      type: :object,
      required: [:job],
      properties: %{
        job: %Schema{
          type: :object,
          required: [:id, :kind, :state, :created_at, :priority, :attempts],
          properties: %{
            id: %Schema{type: :string},
            kind: %Schema{type: :string},
            state: %Schema{type: :string, enum: @states},
            dedupe_key: %Schema{type: :string, nullable: true},
            created_at: %Schema{type: :string, format: :"date-time", nullable: true},
            started_at: %Schema{type: :string, format: :"date-time", nullable: true},
            finished_at: %Schema{type: :string, format: :"date-time", nullable: true},
            priority: %Schema{type: :integer},
            attempts: %Schema{type: :integer},
            result: %Schema{type: :object, nullable: true, additionalProperties: true},
            error: %Schema{type: :object, nullable: true, additionalProperties: true},
            payload: %Schema{
              type: :object,
              nullable: true,
              additionalProperties: true,
              description: "Only with `?include_payload=true`."
            }
          }
        }
      }
    },
    struct?: false
  )
end
