defmodule Butler.CLI.System do
  @moduledoc """
  Real `Butler.CLI` implementation: runs `mempalace` through an Erlang port.

  * Arguments are passed as a list to `{:spawn_executable, ...}`; no shell is
    ever involved.
  * Output (stdout and stderr merged) is streamed line by line to the optional
    `:on_output` callback.
  * Only the last `:max_output_bytes` of output are kept (a tail), so a chatty
    process cannot grow the memory of Butler without bound.
  * `:on_start` receives the OS pid right after the spawn; `:env` adds
    environment variables.
  * On timeout the process is terminated by its OS pid (`SIGTERM`, then
    `SIGKILL` after a short grace period) and `{:error, {:timeout, partial}}`
    is returned.
  """

  @behaviour Butler.CLI

  alias Butler.OSProcess
  alias Butler.Palace

  @default_timeout_ms 30_000
  @default_max_output_bytes 65_536

  @doc "Default timeout, in milliseconds, when none is given."
  @spec default_timeout_ms() :: pos_integer()
  def default_timeout_ms, do: @default_timeout_ms

  @doc "Default size, in bytes, of the output tail kept in memory."
  @spec default_max_output_bytes() :: pos_integer()
  def default_max_output_bytes, do: @default_max_output_bytes

  @impl Butler.CLI
  def run(args, opts \\ []) do
    bin = Keyword.get_lazy(opts, :bin, &Palace.mempalace_bin/0)
    timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

    ctx = %{
      on_output: Keyword.get(opts, :on_output, fn _line -> :ok end),
      on_start: Keyword.get(opts, :on_start, fn _os_pid -> :ok end),
      max_bytes: Keyword.get(opts, :max_output_bytes, @default_max_output_bytes),
      env: Keyword.get(opts, :env, [])
    }

    with :ok <- validate_args(args),
         :ok <- validate_env(ctx.env),
         {:ok, executable} <- OSProcess.find_executable(bin) do
      execute(executable, args, timeout, ctx)
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

  defp validate_env(env) when is_list(env) do
    valid? =
      Enum.all?(env, fn
        {name, value} when is_binary(name) and is_binary(value) ->
          name != "" and not String.contains?(name, ["=", <<0>>]) and
            not String.contains?(value, <<0>>)

        _other ->
          false
      end)

    if valid?, do: :ok, else: {:error, {:invalid_args, env}}
  end

  defp validate_env(env), do: {:error, {:invalid_args, env}}

  defp execute(executable, args, timeout, ctx) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        {:args, args},
        {:env, OSProcess.port_env(ctx.env)}
      ])

    # nil when the process already exited (Port.info/2 returns nil for a closed port).
    os_pid = OSProcess.os_pid(port)
    ctx.on_start.(os_pid)

    deadline = Elixir.System.monotonic_time(:millisecond) + timeout

    collect(
      %{
        port: port,
        os_pid: os_pid,
        deadline: deadline,
        on_output: ctx.on_output,
        max_bytes: ctx.max_bytes
      },
      "",
      ""
    )
  end

  # `tail` is the last `max_bytes` of the lines seen so far, `pending` the
  # current incomplete line.
  defp collect(ctx, tail, pending) do
    remaining = max(ctx.deadline - Elixir.System.monotonic_time(:millisecond), 0)
    port = ctx.port

    receive do
      {^port, {:data, chunk}} ->
        {lines, rest} = split_lines(pending <> chunk)
        Enum.each(lines, ctx.on_output)
        {lines, rest} = bound_pending(lines, rest, ctx)
        added = Enum.map(lines, &[&1, "\n"])
        collect(ctx, keep_tail([tail, added], ctx.max_bytes), rest)

      {^port, {:exit_status, status}} ->
        if pending != "", do: ctx.on_output.(pending)
        {:ok, %{status: status, output: keep_tail([tail, pending], ctx.max_bytes)}}
    after
      remaining ->
        terminate(ctx)
        {:error, {:timeout, keep_tail([tail, pending], ctx.max_bytes)}}
    end
  end

  # A line longer than the budget is emitted as is, so it cannot grow unbounded.
  defp bound_pending(lines, rest, %{max_bytes: max, on_output: on_output})
       when byte_size(rest) > max do
    on_output.(rest)
    {lines ++ [rest], ""}
  end

  defp bound_pending(lines, rest, _ctx), do: {lines, rest}

  defp keep_tail(iodata, max_bytes) do
    data = IO.iodata_to_binary(iodata)
    size = byte_size(data)

    if size <= max_bytes do
      data
    else
      data |> binary_part(size - max_bytes, max_bytes) |> drop_partial_codepoint()
    end
  end

  # The cut may land inside a multi-byte character: drop its continuation bytes.
  defp drop_partial_codepoint(<<byte, rest::binary>>) when byte in 0x80..0xBF,
    do: drop_partial_codepoint(rest)

  defp drop_partial_codepoint(data), do: data

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
