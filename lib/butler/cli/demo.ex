defmodule Butler.CLI.Demo do
  @moduledoc """
  A `Butler.CLI` implementation for demo mode (`mix butler.demo`).

  It **never runs any program**: it answers canned outputs and simulates the
  daemon by creating or removing the demo `endpoint.json`. This makes every
  button of the UI safe to click on demo data.
  """

  @behaviour Butler.CLI

  alias Butler.Daemon.Locator
  alias Butler.Demo
  alias Butler.Palace

  @submit_kinds ~w(mine sweep sync)
  @direct_commands ~w(repair compress migrate-wings)

  @impl Butler.CLI
  def run(["--palace", _palace | args], opts), do: command(args, opts)
  def run(args, opts), do: command(args, opts)

  defp command(["daemon", "stop"], _opts) do
    Demo.remove_endpoint!(daemon_dir())
    ok("MemPalace daemon stopping\n")
  end

  defp command(["daemon", "start"], _opts) do
    Demo.write_endpoint!(daemon_dir())
    ok("MemPalace daemon running on 127.0.0.1:7878\n")
  end

  defp command(["daemon", "status"], _opts), do: ok("MemPalace daemon is running (demo)\n")

  defp command([kind | _] = args, _opts) when kind in @submit_kinds do
    id = Base.encode16(:crypto.hash(:md5, Enum.join(args, "\0")), case: :lower)
    ok("Submitted daemon job #{id} (#{kind})\n")
  end

  defp command([name | _], opts) when name in @direct_commands do
    lines = ["", " MemPalace #{name} (demo)", "  Nothing was changed: this is demo mode.", ""]
    emit = Keyword.get(opts, :on_output, fn _line -> :ok end)
    Enum.each(lines, emit)
    ok(Enum.map_join(lines, "", &(&1 <> "\n")))
  end

  defp command(_args, _opts), do: {:ok, %{status: 2, output: "demo: unsupported command\n"}}

  defp ok(output), do: {:ok, %{status: 0, output: output}}

  defp daemon_dir, do: Path.join(Palace.daemon_root(), Locator.palace_key(Palace.path()))
end
