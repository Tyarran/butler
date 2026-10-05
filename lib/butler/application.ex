defmodule Butler.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        ButlerWeb.Telemetry,
        {DNSCluster, query: Application.get_env(:butler, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Butler.PubSub},
        {Task.Supervisor, name: Butler.TaskSupervisor},
        Butler.Commands.Direct
      ] ++
        watcher_children() ++
        [
          # Start to serve requests, typically the last entry
          ButlerWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Butler.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp watcher_children do
    if Application.get_env(:butler, :start_watcher, true), do: [Butler.Jobs.Watcher], else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    ButlerWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
