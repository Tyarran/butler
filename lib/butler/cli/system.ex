defmodule Butler.CLI.System do
  @moduledoc """
  Real `Butler.CLI` implementation: runs `mempalace` through an Erlang port.

  * Arguments are passed as a list to `{:spawn_executable, ...}`; no shell is
    ever involved.
  * Output (stdout and stderr merged) is streamed line by line to the optional
    `:on_output` callback.
  * On timeout the process is terminated by its OS pid (`SIGTERM`, then
    `SIGKILL` after a short grace period) and `{:error, {:timeout, partial}}`
    is returned.
  """

  @behaviour Butler.CLI

  alias Butler.OSProcess
  alias Butler.Palace

  @default_timeout_ms 30_000

  @doc "Default timeout, in milliseconds, when none is given."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @impl Butler.CLI
  def run(args, opts \\ []) do
    bin = Keyword.get_lazy(opts, :bin, &Palace.mempalace_bin/0)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)
    on_output = Keyword.get(opts, :on_output, fn _line -> :ok end)

    with :ok <- validate_args(args),
         {:ok, executable} <- find_executable(bin) do
      execute(executable, args, timeout, on_output)
    end
  end

  defp validate_args(args) when is_list(args) do
    if Enum.all?(args, &(is_binary(&1) and not String.contains?(&1, <<0>>))) do
      :ok
    else
      {:error, {:invalid_args, args}}
    end
  end

  defp validate_args(args), do: {:error, {:invalid_args, args}}

  defp find_executable(bin) do
    found =
      if String.contains?(bin, "/") do
        if File.regular?(bin), do: bin
      else
        Elixir.System.find_executable(bin)
      end

    if found, do: {:ok, found}, else: {:error, {:executable_not_found, bin}}
  end

  defp execute(executable, args, timeout, on_output) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, args}
      ])

    # nil when the process already exited (Port.info/2 returns nil for a closed port).
    os_pid = OSProcess.os_pid(port)

    deadline = Elixir.System.monotonic_time(:millisecond) + timeout

    collect(%{port: port, os_pid: os_pid, deadline: deadline, on_output: on_output}, [], "")
  end

  defp collect(ctx, acc, pending) do
    remaining = max(ctx.deadline - Elixir.System.monotonic_time(:millisecond), 0)
    port = ctx.port

    receive do
      {^port, {:data, chunk}} ->
        {lines, rest} = split_lines(pending <> chunk)
        Enum.each(lines, ctx.on_output)
        collect(ctx, [acc, Enum.map(lines, &[&1, "\n"])], rest)

      {^port, {:exit_status, status}} ->
        if pending != "", do: ctx.on_output.(pending)
        {:ok, %{status: status, output: IO.iodata_to_binary([acc, pending])}}
    after
      remaining ->
        terminate(ctx)
        {:error, {:timeout, IO.iodata_to_binary([acc, pending])}}
    end
  end

  # Splits on newlines; the last element is the (possibly empty) incomplete line.
  defp split_lines(data) do
    parts = String.split(data, "\n")
    {Enum.drop(parts, -1), List.last(parts)}
  end

  defp terminate(%{port: port, os_pid: os_pid}) do
    OSProcess.signal(os_pid, "TERM")

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      OSProcess.term_grace_ms() ->
        OSProcess.signal(os_pid, "KILL")
        OSProcess.close(port)
    end

    flush(port)
  end

  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end
end
