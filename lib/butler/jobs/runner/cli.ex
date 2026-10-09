defmodule Butler.Jobs.Runner.CLI do
  @moduledoc """
  Runs a CLI job kind (`mine`, `sweep`, `sync`, `repair`, `compress`,
  `migrate-wings`) as an ephemeral `mempalace` process through `Butler.CLI`.

  The argument list comes from `Butler.Jobs.Kinds.argv/3` (always `--direct`)
  and the process gets `Butler.Jobs.Kinds.routing_env/0`. Outcomes:

    * `{:ok, result}` - exit status 0; `result` carries the output tail;
    * `{:lock_refused, output}` - non-zero exit and the output matches the
      palace-lock refusal (see `lock_refused?/1`); the worker re-queues the job;
    * `{:error, error}` - any other failure (`error.class` says which).

  Results and errors are JSON-encodable maps stored in `result_json` /
  `error_json`.
  """

  alias Butler.CLI
  alias Butler.Jobs.Job
  alias Butler.Jobs.Kinds

  # Exit codes and streams of a lock refusal are inconsistent across commands
  # (docs/spikes.md, Q2): match the text on stdout+stderr instead.
  @lock_refusal ~r/palace .+ is held by .+; wait for it to finish or stop the holder before retrying|MineAlreadyRunning/s
  @lock_class "LockHeldByOtherProcess"

  @type outcome :: {:ok, map()} | {:lock_refused, String.t()} | {:error, map()}

  @doc "Butler's own `class` for a refusal caused by the palace lock."
  @spec lock_class() :: String.t()
  def lock_class, do: @lock_class

  @doc "Whether `output` of a failed command is a palace-lock refusal."
  @spec lock_refused?(String.t()) :: boolean()
  def lock_refused?(output) when is_binary(output), do: Regex.match?(@lock_refusal, output)

  @doc """
  Runs `job`.

  Options: `:timeout_ms` (default `Butler.Jobs.Kinds.timeout_ms/1`),
  `:on_start` (called with the OS pid), `:on_output` (called per line),
  `:palace` (palace path override), `:max_output_bytes`.
  """
  @spec run(Job.t(), keyword()) :: outcome()
  def run(%Job{kind: kind, payload: payload}, opts \\ []) do
    palace_opts = Keyword.take(opts, [:palace])

    case Kinds.argv(kind, payload || %{}, palace_opts) do
      {:ok, argv} -> execute(kind, argv, opts)
      {:error, reason} -> {:error, %{class: "InvalidPayload", message: inspect(reason)}}
    end
  end

  defp execute(kind, argv, opts) do
    timeout = Keyword.get_lazy(opts, :timeout_ms, fn -> Kinds.timeout_ms(kind) end)

    cli_opts =
      [timeout: timeout, env: Kinds.routing_env()] ++
        Keyword.take(opts, [:on_start, :on_output, :max_output_bytes])

    argv |> CLI.run(cli_opts) |> outcome(timeout)
  end

  defp outcome({:ok, %{status: 0, output: output}}, _timeout),
    do: {:ok, %{exit_status: 0, output_tail: output}}

  defp outcome({:ok, %{status: status, output: output}}, _timeout) do
    if lock_refused?(output) do
      {:lock_refused, output}
    else
      {:error,
       %{
         class: "CommandFailed",
         message: "mempalace exited with status #{status}",
         exit_status: status,
         output_tail: output
       }}
    end
  end

  defp outcome({:error, {:timeout, partial}}, timeout) do
    {:error,
     %{
       class: "Timeout",
       message: "timed out after #{div(timeout, 1000)}s",
       output_tail: partial
     }}
  end

  defp outcome({:error, {:executable_not_found, bin}}, _timeout),
    do: {:error, %{class: "ExecutableNotFound", message: "executable not found: #{bin}"}}

  defp outcome({:error, {:invalid_args, _} = reason}, _timeout),
    do: {:error, %{class: "InvalidPayload", message: inspect(reason)}}

  defp outcome({:error, reason}, _timeout),
    do: {:error, %{class: "CLIError", message: inspect(reason)}}
end
