defmodule ButlerWeb.MaintenanceHook do
  @moduledoc """
  `on_mount` hook of every LiveView: keeps the `:maintenance` assign
  (`nil`, or `%{job_id: id | nil}` while a `repair`, `compress` or
  `migrate-wings` job owns the palace) up to date, so that `Layouts.app` can
  show the global maintenance banner.

  It subscribes to the worker topic and consumes its messages. Only
  `ButlerWeb.WorkerLive` also receives `{:worker_changed, status}`.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Butler.Jobs.Worker
  alias Butler.Maintenance

  @doc false
  def on_mount(:default, _params, _session, socket) do
    if Phoenix.LiveView.connected?(socket), do: Worker.subscribe()

    socket =
      socket
      |> assign(:maintenance, current())
      |> Phoenix.LiveView.attach_hook(:butler_worker_events, :handle_info, &handle_info/2)

    {:cont, socket}
  end

  defp handle_info({:maintenance_changed, _state}, socket),
    do: {:halt, assign(socket, :maintenance, current())}

  defp handle_info({:worker_changed, _status}, %{view: ButlerWeb.WorkerLive} = socket),
    do: {:cont, socket}

  defp handle_info({:worker_changed, _status}, socket), do: {:halt, socket}
  defp handle_info(_message, socket), do: {:cont, socket}

  defp current do
    if Maintenance.active?(), do: %{job_id: Maintenance.job_id()}
  end
end
