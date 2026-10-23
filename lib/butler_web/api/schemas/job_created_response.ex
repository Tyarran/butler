defmodule ButlerWeb.API.Schemas.JobCreatedResponse do
  @moduledoc "Answer of `POST /api/v1/jobs` (202): the job, new or deduplicated."

  require OpenApiSpex

  alias OpenApiSpex.Schema

  @states ~w(queued running succeeded failed cancelled unknown)

  OpenApiSpex.schema(
    %{
      title: "JobCreatedResponse",
      type: :object,
      required: [:job],
      properties: %{
        job: %Schema{
          type: :object,
          required: [:id, :kind, :state, :created_at, :deduplicated],
          properties: %{
            id: %Schema{type: :string},
            kind: %Schema{type: :string},
            state: %Schema{type: :string, enum: @states},
            dedupe_key: %Schema{type: :string, nullable: true},
            created_at: %Schema{type: :string, format: :"date-time", nullable: true},
            deduplicated: %Schema{
              type: :boolean,
              description: "True when an existing queued or running job was returned."
            }
          }
        }
      }
    },
    struct?: false
  )
end
