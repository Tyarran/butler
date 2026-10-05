defmodule ButlerWeb.Layouts do
  @moduledoc """
  Layouts and navigation of the Butler dashboard.
  """
  use ButlerWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @nav_items [
    %{id: :daemon, label: "Daemon", path: "/daemon", icon: "hero-server"}
  ]

  @doc """
  Navigation entries as maps with `:id`, `:label`, `:path` and `:icon`.
  """
  @spec nav_items() :: [map()]
  def nav_items, do: @nav_items

  @doc """
  Renders the dashboard layout: a sidebar with navigation and theme toggle,
  and the page content.

  ## Examples

      <Layouts.app flash={@flash} active={:daemon}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :active, :atom, default: nil, doc: "the id of the active navigation entry"
  attr :title, :string, default: nil, doc: "optional page heading"

  slot :inner_block, required: true
  slot :actions, doc: "optional actions rendered next to the heading"

  def app(assigns) do
    assigns = assign(assigns, :nav_items, nav_items())

    ~H"""
    <div class="drawer lg:drawer-open min-h-screen bg-base-200">
      <input id="nav-drawer" type="checkbox" class="drawer-toggle" />

      <div class="drawer-content flex flex-col">
        <header class="navbar bg-base-100 border-b border-base-300 lg:hidden">
          <label for="nav-drawer" class="btn btn-ghost btn-square" aria-label="Open navigation">
            <.icon name="hero-bars-3" class="size-5" />
          </label>
          <span class="font-semibold">Butler</span>
        </header>

        <main id="main" class="p-4 sm:p-6 lg:p-8">
          <div class="mx-auto max-w-6xl space-y-6">
            <div
              :if={@title || @actions != []}
              class="flex flex-wrap items-center justify-between gap-3"
            >
              <h1 :if={@title} class="text-2xl font-semibold">{@title}</h1>
              <div :if={@actions != []} class="flex items-center gap-2">
                {render_slot(@actions)}
              </div>
            </div>
            {render_slot(@inner_block)}
          </div>
        </main>
      </div>

      <div class="drawer-side z-20">
        <label for="nav-drawer" aria-label="Close navigation" class="drawer-overlay"></label>
        <aside class="flex min-h-full w-64 flex-col bg-base-100 border-r border-base-300">
          <div class="flex items-center gap-2 px-5 py-5">
            <.icon name="hero-command-line" class="size-6 text-primary" />
            <span class="text-lg font-semibold tracking-tight">Butler</span>
          </div>

          <nav aria-label="Main" class="flex-1 px-2">
            <ul class="menu w-full gap-1">
              <li :for={item <- @nav_items}>
                <.link
                  navigate={item.path}
                  class={if item.id == @active, do: "menu-active", else: ""}
                  aria-current={if item.id == @active, do: "page"}
                >
                  <.icon name={item.icon} class="size-5" />
                  {item.label}
                </.link>
              </li>
            </ul>
          </nav>

          <div class="flex items-center justify-between gap-2 border-t border-base-300 px-4 py-3">
            <span class="text-xs opacity-60">Theme</span>
            <.theme_toggle />
          </div>
        </aside>
      </div>
    </div>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title="We can't find the internet"
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title="Something went wrong!"
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        Attempting to reconnect
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides a system / light / dark theme toggle based on the themes defined in
  `assets/css/app.css`. The choice is stored in `localStorage` and applied
  before page load by the script in `root.html.heex`.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div
      id="theme-toggle"
      class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full"
    >
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
        aria-label="System theme"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
        aria-label="Light theme"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
        aria-label="Dark theme"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
