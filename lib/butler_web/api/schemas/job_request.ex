defmodule ButlerWeb.API.Schemas.JobRequest do
  @moduledoc """
  Body of `POST /api/v1/jobs`.

  Describes the same rules as `ButlerWeb.API.JobParams` (the authority) and is
  never stricter: the `payload` is a free object whose per-kind rules live in
  `Butler.Jobs.Kinds.validate_payload/2`.
  """

  require OpenApiSpex

  alias Butler.Jobs.Kinds
  alias ButlerWeb.API.JobParams
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(
    %{
      title: "JobRequest",
      type: :object,
      additionalProperties: false,
      required: [:kind],
      properties: %{
        kind: %Schema{
          type: :string,
          enum: Kinds.api_kinds(),
          description:
            "The job kind. `repair`, `compress` and `migrate-wings` are UI-only (403).",
          example: "mine"
        },
        payload: %Schema{
          type: :object,
          nullable: true,
          additionalProperties: true,
          description: """
          Kind-specific parameters, validated at submit time. `mine`: source,
          mode, wing, agent, dry_run, limit, no_gitignore, include_ignored,
          extract, max_chunks_per_file, redetect_origin. `sweep`: target.
          `sync`: wing, roots, dry_run (defaults to true). `diary_write`:
          agent_name, entry, topic, wing. `mcp_tool`: name, arguments.
          `palace_path` is never accepted. See docs/api.md.
          """,
          example: %{source: "/tmp/synthetic-sessions", mode: "convos"}
        },
        dedupe_key: %Schema{
          type: :string,
          nullable: true,
          minLength: 1,
          maxLength: JobParams.max_dedupe_key(),
          description: "A job with the same key still queued or running is returned instead."
        },
        priority: %Schema{
          type: :integer,
          nullable: true,
          minimum: -JobParams.max_priority(),
          maximum: JobParams.max_priority(),
          default: 0
        }
      },
      example: %{kind: "mine", payload: %{source: "/tmp/synthetic-sessions"}, dedupe_key: "daily"}
    },
    struct?: false
  )
end
