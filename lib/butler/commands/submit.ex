defmodule Butler.Commands.Submit do
  @moduledoc """
  Submits jobs of the dashboard forms to Butler's own queue.

  The validated form input (`Butler.Commands.Input`) is turned into a job
  payload, checked by `Butler.Jobs.Kinds.validate_payload/2` (the very rules
  the worker applies) and enqueued with `Butler.Jobs.enqueue/3`. Nothing is
  executed here: the serial worker runs the job later.

  Results:

    * `{:ok, job}` - the job is queued;
    * `{:error, {:duplicate, job}}` - an identical job is already queued or
      running (it is returned);
    * `{:error, {:invalid, field, message}}` / `{:error, :unknown_kind}` -
      refused by validation, nothing was enqueued;
    * `{:error, {:unavailable, reason}}` - the job engine does not answer.

  ## Duplicates

  Every submission carries a `dedupe_key` derived from its kind and payload
  (`ui:<kind>:<hash>`), so that the queue's unique index refuses to queue the
  same work twice while it is still queued or running. API clients use their
  own keys.

  ## Sync

  `sync/2` is a dry run unless called with `apply: true`; the form asks for a
  confirmation first. Applying needs a wing or roots (validated by `Kinds`).
  """

  alias Butler.Jobs
  alias Butler.Jobs.Job

  @type input :: %{optional(atom()) => term()}
  @type result ::
          {:ok, Job.t()}
          | {:error,
             {:duplicate, Job.t()}
             | {:invalid, String.t() | nil, String.t()}
             | :unknown_kind
             | {:unavailable, term()}}

  @mine_keys ~w(mode wing agent dry_run limit no_gitignore include_ignored extract
                max_chunks_per_file redetect_origin)a

  @doc "Queues a `mine` job from the validated `Butler.Commands.Input.mine/1` input."
  @spec mine(input()) :: result()
  def mine(input) do
    payload = input |> Map.take(@mine_keys) |> Map.put(:source, input[:dir])
    submit("mine", payload)
  end

  @doc "Queues a `sweep` job from the validated `Butler.Commands.Input.sweep/1` input."
  @spec sweep(input()) :: result()
  def sweep(input), do: submit("sweep", Map.take(input, [:target]))

  @doc """
  Queues a `sync` job from the validated `Butler.Commands.Input.sync/1` input.

  A dry run, unless `apply: true` is given.
  """
  @spec sync(input(), keyword()) :: result()
  def sync(input, opts \\ []) do
    payload =
      input |> Map.take([:wing, :roots]) |> Map.put(:dry_run, !Keyword.get(opts, :apply, false))

    submit("sync", payload)
  end

  @doc """
  Queues a maintenance job (`repair`, `compress` or `migrate-wings`).

  Options: `:dry_run` (default false) and, for `compress`, `:wing`.
  """
  @spec maintenance(String.t(), keyword()) :: result()
  def maintenance(kind, opts \\ []) do
    payload = %{dry_run: Keyword.get(opts, :dry_run, false), wing: Keyword.get(opts, :wing)}
    submit(kind, payload)
  end

  defp submit(kind, payload) do
    payload = compact(payload)

    case Jobs.enqueue(kind, payload, dedupe_key: dedupe_key(kind, payload)) do
      {:ok, job, :created} -> {:ok, job}
      {:ok, job, :deduplicated} -> {:error, {:duplicate, job}}
      {:error, {:queue_unavailable, reason}} -> {:error, {:unavailable, reason}}
      {:error, _reason} = error -> error
    end
  end

  # Blank optional values are not part of the payload (`dry_run: false` of a
  # sync is kept: it is how `--apply` is asked for).
  defp compact(payload) do
    payload
    |> Enum.reject(fn {key, value} -> blank?(key, value) end)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp blank?(:dry_run, value), do: is_nil(value)
  defp blank?(_key, value), do: value in [nil, "", false, []]

  defp dedupe_key(kind, payload) do
    hash =
      :sha256
      |> :crypto.hash(:erlang.term_to_binary({kind, payload}, [:deterministic]))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 32)

    "ui:#{kind}:#{hash}"
  end
end
