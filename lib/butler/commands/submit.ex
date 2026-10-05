defmodule Butler.Commands.Submit do
  @moduledoc """
  Submits `mine`, `sweep` and `sync` (dry run) jobs to the daemon through the
  CLI (`... --daemon --background`) and returns the new job id.

  Results:

    * `{:ok, job_id}`
    * `{:error, {:invalid, field}}` / `{:error, {:unknown_option, key}}` -
      refused by `Butler.Commands.Args`, the CLI is not called;
    * `{:error, {:duplicate, job_id}}` - an identical job is already queued or
      running (its id is returned);
    * `{:error, {:cli, output}}` - the CLI failed, timed out, or printed
      something unexpected.

  ## About duplicates

  The CLI does not set a dedupe key on the jobs it submits (only the hooks
  do), so the daemon never refuses a duplicate: it would simply queue it
  again. Butler therefore compares the request with the active jobs of the
  queue, read-only, *before* calling the CLI. It is a best-effort check: a job
  submitted at the same instant by another client can still slip through.

  > #### The CLI may start the daemon {: .info}
  > `mempalace ... --daemon` starts the daemon when it is not running.
  """

  alias Butler.CLI
  alias Butler.Commands.Args
  alias Butler.Daemon.Status
  alias Butler.Jobs.Job
  alias Butler.Jobs.Store

  @cli_timeout_ms 30_000
  @job_id_pattern ~r/^Submitted daemon job ([0-9A-Za-z_-]+) \(\w+\)\s*$/m
  @active_states [:queued, :running]

  @type result ::
          {:ok, String.t()}
          | {:error,
             {:invalid, atom()}
             | {:unknown_option, atom()}
             | {:duplicate, String.t()}
             | {:cli, String.t()}}

  @doc "Submits a `mine` job. See `Butler.Commands.Args.mine/2` for the input."
  @spec mine(Args.input(), keyword()) :: result()
  def mine(input, opts \\ []), do: submit("mine", Args.mine(input, opts), input, opts)

  @doc "Submits a `sweep` job. See `Butler.Commands.Args.sweep/2` for the input."
  @spec sweep(Args.input(), keyword()) :: result()
  def sweep(input, opts \\ []), do: submit("sweep", Args.sweep(input, opts), input, opts)

  @doc "Submits a `sync --dry-run` job. See `Butler.Commands.Args.sync/2`."
  @spec sync(Args.input(), keyword()) :: result()
  def sync(input, opts \\ []), do: submit("sync", Args.sync(input, opts), input, opts)

  @doc """
  Extracts the job id from the CLI output
  (`Submitted daemon job <id> (<kind>)`).
  """
  @spec parse_job_id(String.t()) :: {:ok, String.t()} | :error
  def parse_job_id(output) do
    case Regex.run(@job_id_pattern, output) do
      [_, id] -> {:ok, id}
      _ -> :error
    end
  end

  defp submit(kind, built, input, opts) do
    with {:ok, args} <- built,
         :ok <- check_duplicate(kind, input, opts) do
      run(args)
    end
  end

  defp run(args) do
    case CLI.run(args, timeout: @cli_timeout_ms) do
      {:ok, %{status: 0, output: output}} -> parse_output(output)
      {:ok, %{output: output}} -> {:error, {:cli, output}}
      {:error, reason} -> {:error, {:cli, describe(reason)}}
    end
  end

  defp parse_output(output) do
    case parse_job_id(output) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, {:cli, output}}
    end
  end

  defp describe({:timeout, partial}), do: "The command timed out. #{partial}"
  defp describe({:executable_not_found, bin}), do: "Executable not found: #{bin}"
  defp describe(other), do: inspect(other)

  defp check_duplicate(kind, input, opts) do
    path = Keyword.get_lazy(opts, :queue_path, fn -> Status.resolve().queue_path end)

    with path when is_binary(path) <- path,
         {:ok, jobs} <- Store.list(path, limit: 1_000),
         %Job{id: id} <- Enum.find(jobs, &identical?(kind, input, &1)) do
      {:error, {:duplicate, id}}
    else
      _ -> :ok
    end
  end

  defp identical?(kind, input, %Job{kind: kind, state: state, payload: %{} = payload})
       when state in @active_states,
       do: fingerprint(kind, input) == payload_fingerprint(kind, payload)

  defp identical?(_kind, _input, _job), do: false

  defp fingerprint("mine", input) do
    %{
      source: input[:dir],
      mode: blank(input[:mode]) || "projects",
      wing: blank(input[:wing]),
      agent: blank(input[:agent]) || "mempalace",
      dry_run: input[:dry_run] == true,
      limit: input[:limit] || 0,
      no_gitignore: input[:no_gitignore] == true,
      include_ignored: split_ignored(input[:include_ignored]),
      extract: blank(input[:extract]) || "exchange",
      max_chunks_per_file: input[:max_chunks_per_file],
      redetect_origin: input[:redetect_origin] == true
    }
  end

  defp fingerprint("sweep", input), do: %{target: input[:target]}

  defp fingerprint("sync", input),
    do: %{wing: blank(input[:wing]), roots: List.wrap(input[:roots]), dry_run: true}

  defp payload_fingerprint("mine", p) do
    %{
      source: p["source"],
      mode: blank(p["mode"]) || "projects",
      wing: blank(p["wing"]),
      agent: blank(p["agent"]) || "mempalace",
      dry_run: p["dry_run"] == true,
      limit: p["limit"] || 0,
      no_gitignore: p["no_gitignore"] == true,
      include_ignored: split_ignored(p["include_ignored"]),
      extract: blank(p["extract"]) || "exchange",
      max_chunks_per_file: p["max_chunks_per_file"],
      redetect_origin: p["redetect_origin"] == true
    }
  end

  defp payload_fingerprint("sweep", p), do: %{target: p["target"]}

  defp payload_fingerprint("sync", p),
    do: %{wing: blank(p["wing"]), roots: List.wrap(p["root"]), dry_run: p["dry_run"] == true}

  defp blank(value) when value in [nil, ""], do: nil
  defp blank(value), do: value

  defp split_ignored(nil), do: []
  defp split_ignored(list) when is_list(list), do: list
  defp split_ignored(text) when is_binary(text), do: String.split(text, ",", trim: true)
end
