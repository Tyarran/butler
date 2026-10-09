defmodule Butler.OSProcess do
  @moduledoc """
  Helpers to stop an OS process Butler spawned through an Erlang port.

  Processes are always addressed by their `os_pid` and signalled with the
  `kill` executable, never through a shell. Shared by `Butler.CLI.System`
  (short-lived commands) and `Butler.MCP.Worker` (long-lived MCP backends).
  """

  @term_grace_ms 2_000

  # Belt and braces next to `--direct`: a process that forgets the flag must
  # never auto-start a daemon nor forward to a hub (docs/spikes.md, Q5).
  @routing_env [
    {"MEMPALACE_CLI_WRITE_ROUTING", "direct"},
    {"MEMPALACE_WRITE_ROUTING", "direct"},
    {"MEMPALACE_HUB_FORWARD", "0"}
  ]

  # Butler reads it as its own configuration (`Butler.Palace.daemon_root/0`),
  # but a spawned process must never inherit it and find the Python daemon.
  @unset_env ["MEMPALACE_DAEMON_STATE_ROOT"]

  @doc "Environment forcing direct write routing on every spawned `mempalace` process."
  @spec routing_env() :: [{String.t(), String.t()}]
  def routing_env, do: @routing_env

  @doc """
  Converts `{name, value}` pairs into the `:env` option of `Port.open/2`.

  The variables of `@unset_env` (`MEMPALACE_DAEMON_STATE_ROOT`) are always
  removed from the inherited environment, whatever Butler itself was given.
  """
  @spec port_env(Enumerable.t()) :: [{charlist(), charlist() | false}]
  def port_env(env) do
    Enum.map(env, fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end) ++
      Enum.map(@unset_env, &{String.to_charlist(&1), false})
  end

  @doc "Grace period, in milliseconds, between `SIGTERM` and `SIGKILL`."
  @spec term_grace_ms() :: pos_integer()
  def term_grace_ms, do: @term_grace_ms

  @doc """
  Resolves `bin`: a path (when it contains a `/`) must be a regular file,
  a bare name is looked up in `PATH`.
  """
  @spec find_executable(String.t()) ::
          {:ok, Path.t()} | {:error, {:executable_not_found, String.t()}}
  def find_executable(bin) do
    found =
      if String.contains?(bin, "/") do
        if File.regular?(bin), do: bin
      else
        System.find_executable(bin)
      end

    if found, do: {:ok, found}, else: {:error, {:executable_not_found, bin}}
  end

  @doc """
  Returns the OS pid of `port`, or `nil` when the port is already closed.
  """
  @spec os_pid(port()) :: non_neg_integer() | nil
  def os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _closed -> nil
    end
  end

  @doc """
  Sends the signal `name` (for example `"TERM"` or `"KILL"`) to `os_pid`.

  A `nil` pid is a no-op, so callers can pass the result of `os_pid/1` as is.
  """
  @spec signal(non_neg_integer() | nil, String.t()) :: :ok
  def signal(nil, _name), do: :ok

  def signal(os_pid, name) when is_integer(os_pid) do
    case System.find_executable("kill") do
      nil ->
        :ok

      kill ->
        {_output, _status} =
          System.cmd(kill, ["-#{name}", Integer.to_string(os_pid)], stderr_to_stdout: true)

        :ok
    end
  end

  @doc "Closes `port`, ignoring a port that is already closed."
  @spec close(port()) :: :ok
  def close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
