defmodule ButlerWeb.JobController do
  @moduledoc """
  Asynchronous job API (`/api/v1/jobs`), see `docs/api.md`.

  `POST` validates the body and the payload of the kind
  (`Butler.Jobs.Kinds.validate_payload/2`), enqueues and answers `202` at
  once; `GET` reads a job. Maintenance kinds are UI-only (`403`).
  """
  use ButlerWeb, :controller

  alias Butler.Jobs.Job
  alias Butler.Jobs.Kinds
  alias Butler.Jobs.Queue
  alias ButlerWeb.APIError
  alias ButlerWeb.JobJSON

  @body_keys ~w(kind payload dedupe_key priority)
  @max_dedupe_key 200

  @doc "Enqueues a job."
  def create(conn, _params) do
    with {:ok, body} <- object(conn.body_params),
         :ok <- known_keys(body),
         {:ok, kind} <- kind(body),
         {:ok, dedupe_key} <- dedupe_key(body),
         {:ok, priority} <- priority(body),
         {:ok, payload} <- payload(kind, body),
         attrs = %{kind: kind, payload: payload, dedupe_key: dedupe_key, priority: priority},
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

  defp invalid(field, message), do: {:error, 400, "invalid_payload", message, field}

  defp object(%{"_json" => _other}), do: invalid(nil, "The body must be a JSON object")
  defp object(%{} = body), do: {:ok, body}

  defp known_keys(body) do
    case Enum.find(Map.keys(body), &(&1 not in @body_keys)) do
      nil -> :ok
      "palace_path" -> invalid("palace_path", "palace_path is not accepted: Butler uses its own")
      key -> invalid(key, "Unknown key")
    end
  end

  defp kind(%{"kind" => kind}) when is_binary(kind) do
    cond do
      kind not in Kinds.kinds() -> {:error, 422, "unknown_kind", "Unknown kind: #{kind}", "kind"}
      Kinds.api_kind?(kind) -> {:ok, kind}
      true -> {:error, 403, "kind_not_allowed", "Kind #{kind} is not available over HTTP", "kind"}
    end
  end

  defp kind(_body), do: invalid("kind", "kind is required and must be a string")

  defp dedupe_key(%{"dedupe_key" => key}) when is_binary(key) do
    if key != "" and String.length(key) <= @max_dedupe_key,
      do: {:ok, key},
      else: invalid("dedupe_key", "dedupe_key must be 1 to #{@max_dedupe_key} characters")
  end

  defp dedupe_key(%{"dedupe_key" => nil}), do: {:ok, nil}

  defp dedupe_key(%{"dedupe_key" => _other}),
    do: invalid("dedupe_key", "dedupe_key must be a string")

  defp dedupe_key(_body), do: {:ok, nil}

  defp priority(%{"priority" => priority}) when is_integer(priority), do: {:ok, priority}
  defp priority(%{"priority" => nil}), do: {:ok, 0}
  defp priority(%{"priority" => _other}), do: invalid("priority", "priority must be an integer")
  defp priority(_body), do: {:ok, 0}

  defp payload(kind, body) do
    case Kinds.validate_payload(kind, Map.get(body, "payload")) do
      {:ok, payload} -> {:ok, payload}
      {:error, {:invalid, field, message}} -> invalid(payload_field(field), message)
      {:error, :unknown_kind} -> {:error, 422, "unknown_kind", "Unknown kind: #{kind}", "kind"}
    end
  end

  defp payload_field(nil), do: nil
  defp payload_field("payload"), do: "payload"
  defp payload_field(field), do: "payload." <> field

  defp enqueue(attrs) do
    case Queue.enqueue(Queue, attrs) do
      {:ok, _job, _outcome} = ok -> ok
      {:error, _reason} -> {:error, 503, "queue_unavailable", "The job queue is unavailable", nil}
    end
  end
end
