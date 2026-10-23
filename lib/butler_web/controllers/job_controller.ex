defmodule ButlerWeb.JobController do
  @moduledoc """
  Asynchronous job API (`/api/v1/jobs`), see `docs/api.md`.

  `POST` validates the body (`ButlerWeb.API.JobParams`) and the payload of the
  kind (`Butler.Jobs.Kinds.validate_payload/2`), enqueues and answers `202` at
  once; `GET` reads a job. Maintenance kinds are UI-only (`403`).
  """
  use ButlerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Butler.Jobs.Job
  alias Butler.Jobs.Queue
  alias ButlerWeb.API.JobParams
  alias ButlerWeb.API.RenderError
  alias ButlerWeb.API.Schemas.ErrorResponse
  alias ButlerWeb.API.Schemas.JobCreatedResponse
  alias ButlerWeb.API.Schemas.JobRequest
  alias ButlerWeb.API.Schemas.JobResponse
  alias ButlerWeb.APIError
  alias ButlerWeb.JobJSON

  # The cast only checks the shape and renders through `RenderError`; the
  # controller keeps its string-keyed `params` and `body_params`.
  plug OpenApiSpex.Plug.CastAndValidate,
       [render_error: RenderError, replace_params: false] when action == :create

  tags(["jobs"])

  operation(:create,
    summary: "Enqueue a job",
    description: """
    Validates the body and the payload of the kind, enqueues the job and answers
    at once. A job with the same `dedupe_key` still queued or running is
    returned instead (`deduplicated: true`).
    """,
    request_body: {"The job to enqueue", "application/json", JobRequest, required: true},
    responses: [
      accepted: {"The job, new or deduplicated", "application/json", JobCreatedResponse},
      bad_request:
        {"Malformed body or payload (invalid_payload)", "application/json", ErrorResponse},
      unauthorized: {"Missing or wrong token (unauthorized)", "application/json", ErrorResponse},
      forbidden:
        {"Not a loopback client (forbidden) or UI-only kind (kind_not_allowed)",
         "application/json", ErrorResponse},
      request_entity_too_large: {"Body over 1 MB (too_large)", "application/json", ErrorResponse},
      unprocessable_entity: {"Unknown kind (unknown_kind)", "application/json", ErrorResponse},
      service_unavailable:
        {"Queue not running (queue_unavailable)", "application/json", ErrorResponse}
    ]
  )

  @doc "Enqueues a job."
  def create(conn, _params) do
    with {:ok, attrs} <- JobParams.validate(conn.body_params),
         {:ok, %Job{} = job, outcome} <- enqueue(attrs) do
      conn
      |> put_status(202)
      |> put_view(json: JobJSON)
      |> render(:created, job: job, deduplicated: outcome == :deduplicated)
    else
      {:error, status, code, message, field} ->
        APIError.render(conn, status, code, message, field)
    end
  end

  operation(:show,
    summary: "Show a job",
    description: "The payload (verbatim content) is only returned with `include_payload=true`.",
    parameters: [
      id: [in: :path, description: "The job id", type: :string, required: true],
      include_payload: [
        in: :query,
        description: "Only the literal `true` includes the payload; any other value omits it.",
        type: :boolean,
        required: false
      ]
    ],
    responses: [
      ok: {"The job", "application/json", JobResponse},
      unauthorized: {"Missing or wrong token (unauthorized)", "application/json", ErrorResponse},
      forbidden: {"Not a loopback client (forbidden)", "application/json", ErrorResponse},
      not_found: {"Unknown job id (not_found)", "application/json", ErrorResponse},
      service_unavailable:
        {"Queue not running (queue_unavailable)", "application/json", ErrorResponse}
    ]
  )

  @doc "Shows a job; the payload only with `?include_payload=true`."
  def show(conn, %{"id" => id} = params) do
    case Queue.get(Queue, id) do
      {:ok, %Job{} = job} ->
        conn
        |> put_view(json: JobJSON)
        |> render(:show, job: job, include_payload: params["include_payload"] == "true")

      {:error, :job_not_found} ->
        APIError.render(conn, 404, "not_found", "Job not found")

      {:error, _reason} ->
        unavailable(conn)
    end
  end

  defp unavailable(conn),
    do: APIError.render(conn, 503, "queue_unavailable", "The job queue is unavailable")

  defp enqueue(attrs) do
    case Queue.enqueue(Queue, attrs) do
      {:ok, _job, _outcome} = ok -> ok
      {:error, _reason} -> {:error, 503, "queue_unavailable", "The job queue is unavailable", nil}
    end
  end
end
