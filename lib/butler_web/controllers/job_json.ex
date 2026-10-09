defmodule ButlerWeb.JobJSON do
  @moduledoc """
  JSON representation of a job for the HTTP API.

  The payload (verbatim diary / tool content) is only included on request
  (`include_payload: true`).
  """

  alias Butler.Jobs.Job

  @doc "The answer of `POST /api/v1/jobs`: `deduplicated` tells a dedupe hit."
  @spec created(%{job: Job.t(), deduplicated: boolean()}) :: map()
  def created(%{job: job, deduplicated: deduplicated}) do
    %{job: job |> summary() |> Map.put(:deduplicated, deduplicated)}
  end

  @doc "The answer of `GET /api/v1/jobs/:id`."
  @spec show(%{job: Job.t(), include_payload: boolean()}) :: map()
  def show(%{job: job, include_payload: include_payload}) do
    full =
      job
      |> summary()
      |> Map.merge(%{
        priority: job.priority,
        attempts: job.attempts,
        started_at: time(job.started_at),
        finished_at: time(job.finished_at),
        result: job.result,
        error: job.error
      })

    %{job: if(include_payload, do: Map.put(full, :payload, job.payload), else: full)}
  end

  defp summary(%Job{} = job) do
    %{
      id: job.id,
      kind: job.kind,
      state: job.state,
      dedupe_key: job.dedupe_key,
      created_at: time(job.created_at)
    }
  end

  defp time(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)
  defp time(_other), do: nil
end
