defmodule Butler.Jobs.Job do
  @moduledoc """
  A job of the MemPalace daemon queue, parsed from a `jobs` table row.

  Parsing is tolerant: malformed JSON columns are kept as raw strings,
  unparseable timestamps become `nil` and unknown states become `:unknown`
  (atoms are never created from database content).
  """

  @states %{
    "queued" => :queued,
    "running" => :running,
    "succeeded" => :succeeded,
    "failed" => :failed,
    "cancelled" => :cancelled
  }
  @active_states [:queued, :running]

  defstruct [
    :id,
    :kind,
    :dedupe_key,
    :created_at,
    :started_at,
    :finished_at,
    :payload,
    :result,
    :error,
    state: :unknown,
    priority: 0,
    attempts: 0
  ]

  @type state :: :queued | :running | :succeeded | :failed | :cancelled | :unknown

  @type t :: %__MODULE__{
          id: String.t(),
          kind: String.t() | nil,
          state: state(),
          priority: integer(),
          dedupe_key: String.t() | nil,
          created_at: DateTime.t() | nil,
          started_at: DateTime.t() | nil,
          finished_at: DateTime.t() | nil,
          payload: term(),
          result: term(),
          error: term(),
          attempts: non_neg_integer()
        }

  @doc """
  Builds a job from a map of column name (string) to raw database value.

  JSON columns (`payload_json`, `result_json`, `error_json`) are decoded; if
  decoding fails the raw string is kept.
  """
  @spec from_row(%{optional(String.t()) => term()}) :: t()
  def from_row(row) when is_map(row) do
    %__MODULE__{
      id: row["id"],
      kind: row["kind"],
      state: Map.get(@states, row["state"], :unknown),
      priority: row["priority"] || 0,
      dedupe_key: row["dedupe_key"],
      created_at: parse_datetime(row["created_at"]),
      started_at: parse_datetime(row["started_at"]),
      finished_at: parse_datetime(row["finished_at"]),
      payload: decode_json(row["payload_json"]),
      result: decode_json(row["result_json"]),
      error: decode_json(row["error_json"]),
      attempts: row["attempts"] || 0
    }
  end

  @doc "Whether the job is queued or running."
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{state: state}), do: state in @active_states

  @doc """
  Duration of the job in seconds.

  Elapsed time so far for a running job, `finished_at - started_at` for a
  finished one, `nil` when it cannot be determined (e.g. still queued).
  """
  @spec duration(t(), DateTime.t()) :: non_neg_integer() | nil
  def duration(job, now \\ DateTime.utc_now())

  def duration(%__MODULE__{state: :running, started_at: %DateTime{} = started}, now),
    do: seconds_between(started, now)

  def duration(%__MODULE__{started_at: %DateTime{} = s, finished_at: %DateTime{} = f}, _now),
    do: seconds_between(s, f)

  def duration(%__MODULE__{}, _now), do: nil

  defp seconds_between(from, to), do: max(DateTime.diff(to, from, :second), 0)

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp decode_json(nil), do: nil
  defp decode_json(""), do: nil

  defp decode_json(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> value
    end
  end

  defp decode_json(value), do: value
end
