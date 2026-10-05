defmodule Butler.Daemon.Control do
  @moduledoc """
  Starts, stops and restarts the MemPalace daemon through the CLI.

  All calls go through `Butler.CLI` with an argument list and a timeout. The
  palace is always passed explicitly with the global `--palace` flag.

  `daemon stop` returns before the daemon has actually exited (it drains the
  running job for up to 10 seconds, then marks it `cancelled`), so `restart/1`
  polls `Butler.Daemon.Status` with a capped wait before starting again.
  """

  alias Butler.CLI
  alias Butler.Daemon.Status
  alias Butler.Palace

  @cli_timeout_ms 30_000
  @poll_ms 250
  @max_wait_ms 20_000

  @type opt ::
          {:status, (-> Status.t())}
          | {:sleep, (non_neg_integer() -> any())}
          | {:poll_ms, pos_integer()}
          | {:max_wait_ms, pos_integer()}
          | {:on_output, (String.t() -> any())}

  @type result :: {:ok, String.t()} | {:error, term()}

  @doc "Starts the daemon (detached). Succeeds if it is already running."
  @spec start([opt()]) :: result()
  def start(opts \\ []), do: daemon_command("start", opts)

  @doc "Asks the daemon to stop. Succeeds if it is already stopped."
  @spec stop([opt()]) :: result()
  def stop(opts \\ []), do: daemon_command("stop", opts)

  @doc """
  Waits until the daemon is stopped, polling its status.

  Options: `:status` (status function, defaults to `Butler.Daemon.Status.resolve/0`),
  `:poll_ms`, `:max_wait_ms` and `:sleep`.
  """
  @spec wait_stopped([opt()]) :: :ok | {:error, :stop_timeout}
  def wait_stopped(opts \\ []) do
    status = Keyword.get(opts, :status, &Status.resolve/0)
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    poll_ms = Keyword.get(opts, :poll_ms, @poll_ms)
    max_wait_ms = Keyword.get(opts, :max_wait_ms, @max_wait_ms)

    poll(status, sleep, poll_ms, max_wait_ms)
  end

  @doc "Stops the daemon, waits for it to be stopped, then starts it again."
  @spec restart([opt()]) :: result()
  def restart(opts \\ []) do
    with {:ok, _output} <- stop(opts),
         :ok <- wait_stopped(opts) do
      start(opts)
    end
  end

  defp poll(status, sleep, poll_ms, remaining_ms) do
    cond do
      status.().state == :stopped ->
        :ok

      remaining_ms <= 0 ->
        {:error, :stop_timeout}

      true ->
        sleep.(poll_ms)
        poll(status, sleep, poll_ms, remaining_ms - poll_ms)
    end
  end

  defp daemon_command(action, opts) do
    cli_opts =
      case Keyword.fetch(opts, :on_output) do
        {:ok, callback} -> [timeout: @cli_timeout_ms, on_output: callback]
        :error -> [timeout: @cli_timeout_ms]
      end

    case CLI.run(["--palace", Palace.path(), "daemon", action], cli_opts) do
      {:ok, %{status: 0, output: output}} -> {:ok, output}
      {:ok, %{} = failure} -> {:error, {:cli, failure}}
      {:error, _reason} = error -> error
    end
  end
end
