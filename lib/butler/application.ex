defmodule Butler.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  alias Butler.MCP

  @impl true
  def start(_type, _args) do
    children =
      [
        ButlerWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:butler, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Butler.PubSub},
        {Task.Supervisor, name: Butler.TaskSupervisor},
        Butler.Maintenance,
        Butler.MCP.Writer
      ] ++
        mcp_children() ++
        jobs_children() ++
        [
          # Start to serve requests, typically the last entry
          ButlerWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Butler.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # The job engine (queue + worker) starts after the MCP proxy it gates.
  defp jobs_children do
    if Application.get_env(:butler, :start_jobs, true), do: [Butler.Jobs.Supervisor], else: []
  end

  defp mcp_children do
    if MCP.Config.enabled?(), do: [MCP.Supervisor], else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ButlerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
