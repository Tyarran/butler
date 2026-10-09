defmodule Butler.CLI.Demo do
  @moduledoc """
  A `Butler.CLI` implementation for demo mode (`mix butler.demo`).

  It **never runs any program**: it answers canned outputs, line by line with
  a short pause so that live output is visible in the dashboard. This makes
  every button of the UI safe to click on demo data.
  """

  @behaviour Butler.CLI

  @commands ~w(mine sweep sync repair compress migrate-wings)
  @default_pause_ms 400

  @impl Butler.CLI
  def run(["--palace", _palace | args], opts), do: command(args, opts)
  def run(args, opts), do: command(args, opts)

  defp command([name | _], opts) when name in @commands do
    lines = ["", " MemPalace #{name} (demo)", "  Nothing was changed: this is demo mode.", ""]
    emit = Keyword.get(opts, :on_output, fn _line -> :ok end)

    Enum.each(lines, fn line ->
      Process.sleep(Application.get_env(:butler, :demo_line_pause_ms, @default_pause_ms))
      emit.(line)
    end)

    {:ok, %{status: 0, output: Enum.map_join(lines, "", &(&1 <> "\n"))}}
  end

  defp command(_args, _opts), do: {:ok, %{status: 2, output: "demo: unsupported command\n"}}
end
