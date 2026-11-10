defmodule ButlerWeb.HealthController do
  @moduledoc """
  `GET /api/v1/health`: worker status, active job, maintenance flag and job
  counts. `503` (with `ok: false`) when the queue or the worker is down.
  """
  use ButlerWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Butler.Jobs.Queue
  alias Butler.Jobs.Worker
  alias Butler.Maintenance
  alias ButlerWeb.API.Schemas.ErrorResponse
  alias ButlerWeb.API.Schemas.HealthResponse

  tags(["health"])

  operation(:show,
    summary: "Engine health",
    responses: [
      ok: {"The engine is healthy", "application/json", HealthResponse},
      service_unavailable:
        {"The queue or the worker is down (ok: false)", "application/json", HealthResponse},
      unauthorized: {"Missing or wrong token (unauthorized)", "application/json", ErrorResponse},
      forbidden: {"Not a loopback client (forbidden)", "application/json", ErrorResponse}
    ]
  )

  @doc "Reports the health of the engine."
  def show(conn, _params) do
    {worker, active_job_id} = worker_status()

    counts =
      case Queue.counts(Queue) do
        {:ok, counts} -> Map.new(counts, fn {state, n} -> {Atom.to_string(state), n} end)
        {:error, _reason} -> nil
      end

    ok = worker != "unavailable" and counts != nil

    conn
    |> put_status(if(ok, do: 200, else: 503))
    |> json(%{
      ok: ok,
      worker: worker,
      active_job_id: active_job_id,
      maintenance: Maintenance.active?(),
      counts: counts
    })
  end

  defp worker_status do
    %{status: status, active_job_id: id} = Worker.status()
    {Atom.to_string(status), id}
  catch
    :exit, _reason -> {"unavailable", nil}
  end
end
