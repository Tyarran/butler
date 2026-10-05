defmodule Butler.CLI do
  @moduledoc """
  The single door to the `mempalace` executable.

  Every call is made with an **argument list** (never a shell string) and has
  a **timeout**. The real implementation is `Butler.CLI.System`; tests use a
  Mox mock (`Butler.CLIMock`) configured through `config :butler, :cli`.

  `args` do not include the executable itself: `run(["daemon", "status"], [])`
  runs `mempalace daemon status`.
  """

  @default_impl Butler.CLI.System

  @typedoc "Options accepted by `c:run/2`."
  @type opts :: [
          timeout: pos_integer(),
          on_output: (String.t() -> any()),
          bin: String.t()
        ]

  @typedoc "Outcome of a finished command: its exit status and combined stdout/stderr."
  @type output :: %{status: integer(), output: String.t()}

  @type error ::
          {:timeout, partial_output :: String.t()}
          | {:executable_not_found, String.t()}
          | {:invalid_args, term()}

  @doc """
  Runs `mempalace` with `args`.

  Options:

    * `:timeout` - milliseconds before the process is killed
      (default `Butler.CLI.System.default_timeout_ms/0`)
    * `:on_output` - called with each output line as it arrives (streaming)
    * `:bin` - executable override (defaults to `Butler.Palace.mempalace_bin/0`)

  Returns `{:ok, %{status: status, output: output}}` whenever the process ran
  to completion, whatever its exit status.
  """
  @callback run(args :: [String.t()], opts()) :: {:ok, output()} | {:error, error()}

  @doc "Runs `mempalace` through the configured implementation. See `c:run/2`."
  @spec run([String.t()], opts()) :: {:ok, output()} | {:error, error()}
  def run(args, opts \\ []), do: impl().run(args, opts)

  defp impl, do: Application.get_env(:butler, :cli, @default_impl)
end
