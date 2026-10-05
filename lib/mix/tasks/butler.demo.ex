defmodule Mix.Tasks.Butler.Demo do
  @shortdoc "Runs Butler on synthetic demo data"

  @moduledoc """
  Runs Butler on **synthetic** demo data, without touching any MemPalace.

      mix butler.demo [--dir DIR] [--port PORT] [--build-only]

  It builds a demo MemPalace home (`BUTLER_MEMPALACE_HOME` fixture
  directory) containing a fake palace and a job queue with jobs in every
  state, then starts the web server on it.

  In demo mode the `mempalace` CLI is replaced by `Butler.CLI.Demo`, which
  runs no program: every button is safe to click.

  ## Options

    * `--dir` - where to build the demo home (default `tmp/demo`)
    * `--port` - HTTP port (default `4000`)
    * `--build-only` - only build the demo home and print its path
  """

  use Mix.Task

  alias Butler.Demo
  alias Mix.Tasks.Phx.Server, as: PhxServer

  @default_dir "tmp/demo"
  @default_port 4000

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args, strict: [dir: :string, port: :integer, build_only: :boolean])

    Mix.Task.run("app.config")
    demo = opts |> Keyword.get(:dir, @default_dir) |> Demo.build!()

    Mix.shell().info("Demo home built in #{demo.home} (palace: #{demo.palace})")

    unless opts[:build_only] do
      configure(demo, Keyword.get(opts, :port, @default_port))
      Mix.shell().info("Demo mode: no mempalace command is ever executed.")
      PhxServer.run([])
    end
  end

  defp configure(demo, port) do
    Application.put_env(:butler, :palace_path, demo.palace)
    Application.put_env(:butler, :mempalace_home, demo.home)
    Application.put_env(:butler, :daemon_state_root, nil)
    Application.put_env(:butler, :cli, Butler.CLI.Demo)

    endpoint = Application.get_env(:butler, ButlerWeb.Endpoint, [])
    http = endpoint |> Keyword.get(:http, []) |> Keyword.put(:port, port)
    Application.put_env(:butler, ButlerWeb.Endpoint, Keyword.put(endpoint, :http, http))
  end
end
