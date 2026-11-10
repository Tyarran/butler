defmodule ButlerWeb.API.JobParams do
  @moduledoc """
  The validation chain of the body of `POST /api/v1/jobs`.

  The checks run in a fixed order (object, known keys, kind, `dedupe_key`,
  `priority`, payload) and the first failure wins. This module is the
  authority for the error codes, messages and fields documented in
  `docs/api.md`: the OpenAPI schema (`ButlerWeb.API.Schemas.JobRequest`) only
  describes the same rules and is never stricter, and
  `ButlerWeb.API.RenderError` re-runs this chain to render cast errors.
  The semantic rules of each payload stay in `Butler.Jobs.Kinds.validate_payload/2`.
  """

  alias Butler.Jobs.Kinds

  @body_keys ~w(kind payload dedupe_key priority)
  @max_dedupe_key 200
  @max_priority 1_000_000

  @typedoc "The attributes handed to `Butler.Jobs.Queue.enqueue/2`."
  @type attrs :: %{
          kind: String.t(),
          payload: map(),
          dedupe_key: String.t() | nil,
          priority: integer()
        }

  @typedoc "`{:error, status, code, message, field}`, as taken by `ButlerWeb.APIError.render/5`."
  @type error :: {:error, pos_integer(), String.t(), String.t(), String.t() | nil}

  @doc "The accepted top-level keys of the body."
  @spec body_keys() :: [String.t()]
  def body_keys, do: @body_keys

  @doc "The maximum length of a `dedupe_key`."
  @spec max_dedupe_key() :: pos_integer()
  def max_dedupe_key, do: @max_dedupe_key

  @doc "The absolute bound of a `priority`."
  @spec max_priority() :: pos_integer()
  def max_priority, do: @max_priority

  @doc "Validates the (string-keyed) body and builds the job attributes."
  @spec validate(map()) :: {:ok, attrs()} | error()
  def validate(params) do
    with {:ok, body} <- object(params),
         :ok <- known_keys(body),
         {:ok, kind} <- kind(body),
         {:ok, dedupe_key} <- dedupe_key(body),
         {:ok, priority} <- priority(body),
         {:ok, payload} <- payload(kind, body) do
      {:ok, %{kind: kind, payload: payload, dedupe_key: dedupe_key, priority: priority}}
    end
  end

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

  defp priority(%{"priority" => priority})
       when is_integer(priority) and abs(priority) <= @max_priority,
       do: {:ok, priority}

  defp priority(%{"priority" => priority}) when is_integer(priority),
    do: invalid("priority", "priority must be between -#{@max_priority} and #{@max_priority}")

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
end
