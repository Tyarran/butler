defmodule Butler.OSProcess do
  @moduledoc """
  Helpers to stop an OS process Butler spawned through an Erlang port.

  Processes are always addressed by their `os_pid` and signalled with the
  `kill` executable, never through a shell. Shared by `Butler.CLI.System`
  (short-lived commands) and `Butler.MCP.Worker` (long-lived MCP backends).
  """

  @term_grace_ms 2_000

  @doc "Grace period, in milliseconds, between `SIGTERM` and `SIGKILL`."
  @spec term_grace_ms() :: pos_integer()
  def term_grace_ms, do: @term_grace_ms

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
