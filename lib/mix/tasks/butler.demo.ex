defmodule Mix.Tasks.Butler.Demo do
  @shortdoc "Runs Butler on synthetic demo data"

  @moduledoc """
  Runs Butler on **synthetic** demo data, without touching any MemPalace.

      mix butler.demo [--dir DIR] [--port PORT] [--build-only]

  It builds a demo state directory (`BUTLER_STATE_DIR`, `<dir>/state`)
  containing a job queue with queued and finished jobs (never a running one), then starts the web server
  on it.

  In demo mode the `mempalace` CLI is replaced by `Butler.CLI.Demo`, which
  runs no program, and the MCP binaries point to nonexistent paths: every
  button is safe to click.

  ## Options

    * `--dir` - where to build the demo (default `tmp/demo`)
    * `--port` - HTTP port (default `4000`)
    * `--build-only` - only build the demo and print its path
  """

  use Mix.Task

  alias Butler.Demo
  alias Mix.Tasks.Phx.Server, as: PhxServer

  @default_dir "tmp/demo"
  @default_port 4000
  @no_binary "/nonexistent/butler-demo"

  @impl Mix.Task
  def run(args) do
    {opts, _argv, _invalid} =
      OptionParser.parse(args, strict: [dir: :string, port: :integer, build_only: :boolean])

    Mix.Task.run("app.config")
    demo = opts |> Keyword.get(:dir, @default_dir) |> Demo.build!()

    Mix.shell().info("Demo built in #{demo.home} (palace: #{demo.palace})")

    unless opts[:build_only] do
      configure(demo, Keyword.get(opts, :port, @default_port))
      Mix.shell().info("Demo mode: no mempalace command is ever executed.")
      PhxServer.run([])
    end
  end

  defp configure(demo, port) do
    Application.put_env(:butler, :state_dir, demo.state_dir)
    Application.put_env(:butler, :palace_path, demo.palace)
    Application.put_env(:butler, :mempalace_home, demo.home)
    Application.put_env(:butler, :daemon_state_root, nil)
    Application.put_env(:butler, :cli, Butler.CLI.Demo)
    # No MCP backend process in demo mode: the MCP page shows synthetic data,
    # and no real binary can ever be spawned (by the writer either).
    Application.put_env(:butler, :start_mcp, false)
    Application.put_env(:butler, :mcp_demo, true)

    Application.put_env(:butler, :mcp,
      backends: %{
        full: [bin: @no_binary <> "/mempalace-mcp"],
        light: [bin: @no_binary <> "/mempalace-light-mcp"]
      }
    )

    endpoint = Application.get_env(:butler, ButlerWeb.Endpoint, [])
    http = endpoint |> Keyword.get(:http, []) |> Keyword.put(:port, port)
    Application.put_env(:butler, ButlerWeb.Endpoint, Keyword.put(endpoint, :http, http))
  end
end
