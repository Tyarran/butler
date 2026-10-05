defmodule ButlerWeb.PalaceLive do
  @moduledoc """
  Placeholder for the palace visualization (not part of v1).
  """
  use ButlerWeb, :live_view

  @impl Phoenix.LiveView
  def mount(_params, _session, socket), do: {:ok, assign(socket, page_title: "Palace")}

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:palace} title="Palace">
      <div
        id="palace-placeholder"
        class="rounded-box border border-dashed border-base-300 bg-base-100 p-10 text-center"
      >
        <.icon name="hero-building-library" class="mx-auto size-10 opacity-50" />
        <p class="mt-3 text-lg font-medium">Coming soon</p>
        <p class="mt-1 text-sm opacity-70">
          A visualization of the palace (wings, rooms, hallways and tunnels) will live here.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
