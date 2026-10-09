defmodule Butler.Daemon.Legacy do
  @moduledoc """
  Detects whether the legacy MemPalace Python daemon is still alive.

  Butler replaces that daemon; two writers on one palace must never run at the
  same time, so the worker stays blocked while this returns `true`.

  The check is **PID liveness only**: the PID comes from the daemon's
  `endpoint.json` (see `Butler.Daemon.Locator`; the `token` file is never
  opened) and is tested through `/proc`. The daemon is never called.
  """

  alias Butler.Daemon.Locator
  alias Butler.Palace

  @proc_root "/proc"

  @type opt :: {:root, Path.t()} | {:palace_path, Path.t()} | {:proc_root, Path.t()}

  @doc """
  Whether the legacy daemon of the configured palace is running.

  Options (mainly for tests): `:root`, `:palace_path`, `:proc_root`.
  """
  @spec running?([opt()]) :: boolean()
  def running?(opts \\ []) do
    root = Keyword.get_lazy(opts, :root, &Palace.daemon_root/0)
    palace = Keyword.get_lazy(opts, :palace_path, &Palace.path/0)

    case Locator.find(root, palace) do
      {:ok, %Locator{pid: pid}} when is_integer(pid) ->
        pid_alive?(pid, Keyword.get(opts, :proc_root, @proc_root))

      _none ->
        false
    end
  end

  # Linux only: liveness relies on `/proc`. A recycled PID could keep the
  # worker blocked until the daemon's own cleanup removes its endpoint.
  defp pid_alive?(pid, proc_root), do: File.dir?(Path.join(proc_root, "#{pid}"))
end
