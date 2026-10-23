defmodule ButlerWeb.API.Schemas.ErrorResponse do
  @moduledoc """
  Error body of the API: an `error` object with `code`, `message` and, for
  payload errors that point at a key, `field`.
  """

  require OpenApiSpex

  alias OpenApiSpex.Schema

  @codes ~w(invalid_payload unauthorized forbidden kind_not_allowed not_found too_large unknown_kind queue_unavailable)

  OpenApiSpex.schema(
    %{
      title: "ErrorResponse",
      type: :object,
      required: [:error],
      properties: %{
        error: %Schema{
          type: :object,
          required: [:code, :message],
          properties: %{
            code: %Schema{type: :string, enum: @codes},
            message: %Schema{type: :string},
            field: %Schema{type: :string, description: "The offending key, when there is one."}
          }
        }
      }
    },
    struct?: false
  )
end
