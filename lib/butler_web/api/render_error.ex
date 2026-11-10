defmodule ButlerWeb.API.RenderError do
  @moduledoc """
  Error renderer of `OpenApiSpex.Plug.CastAndValidate` for `POST /api/v1/jobs`.

  It does **not** translate cast errors: the API's error codes, messages and
  fields are the ones of `ButlerWeb.API.JobParams.validate/1`, so this plug
  re-runs that chain on the body and renders its first error through
  `ButlerWeb.APIError`. When the chain accepts a body the schema refused (the
  schema must never be stricter than the rules, a drift test guards that),
  the answer is a `400 invalid_payload` built from the first cast error.
  """

  @behaviour Plug

  alias ButlerWeb.API.JobParams
  alias ButlerWeb.APIError
  alias OpenApiSpex.Cast.Error

  @impl Plug
  def init(errors), do: errors

  @impl Plug
  def call(conn, errors) do
    case JobParams.validate(conn.body_params) do
      {:error, status, code, message, field} ->
        APIError.render(conn, status, code, message, field)

      {:ok, _attrs} ->
        {message, field} = describe(errors)
        APIError.render(conn, 400, "invalid_payload", message, field)
    end
  end

  defp describe([%Error{reason: reason} | _rest])
       when reason in [:missing_header, :invalid_header],
       do: {"The Content-Type must be application/json", nil}

  defp describe([%Error{} = error | _rest]) do
    field = if error.path == [], do: nil, else: Enum.map_join(error.path, ".", &to_string/1)
    {OpenApiSpex.error_message(error), field}
  end

  defp describe(_errors), do: {"The request body is invalid", nil}
end
