defmodule ButlerWeb.DaemonLive do
  @moduledoc """
  Daemon status page: running state, PID, palace and job counters.

  Refreshes whenever `Butler.Jobs.Watcher` broadcasts a queue change.
  """
  use ButlerWeb, :live_view

  alias Butler.Daemon.Status
  alias Butler.Jobs.Watcher
  alias ButlerWeb.Format

  @counters [
    queued: {"Queued", "hero-clock", :info},
    running: {"Running", "hero-arrow-path", :warning},
    succeeded: {"Succeeded", "hero-check-circle", :success},
    failed: {"Failed", "hero-x-circle", :error},
    cancelled: {"Cancelled", "hero-no-symbol", :default}
  ]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Watcher.subscribe()

    {:ok, socket |> assign(page_title: "Daemon", counters: @counters) |> load_status()}
  end

  @impl Phoenix.LiveView
  def handle_info({:queue_changed, _snapshot}, socket), do: {:noreply, load_status(socket)}

  defp load_status(socket), do: assign(socket, status: Status.resolve(), now: DateTime.utc_now())

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:daemon} title="Daemon">
      <section id="daemon-state" class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm">
        <div class="flex flex-wrap items-center gap-3">
          <.status_badge state={@status.state} kind={:daemon} class="badge-lg" />
          <span class="text-sm opacity-70">MemPalace daemon</span>
        </div>

        <dl class="mt-4 grid gap-x-8 gap-y-3 sm:grid-cols-3">
          <div>
            <dt class="text-xs uppercase opacity-60">Palace</dt>
            <dd class="break-all font-mono text-sm">{@status.palace_path}</dd>
          </div>
          <div>
            <dt class="text-xs uppercase opacity-60">PID</dt>
            <dd class="font-mono text-sm">{@status.pid || "—"}</dd>
          </div>
          <div>
            <dt class="text-xs uppercase opacity-60">Started</dt>
            <dd class="text-sm">
              {Format.datetime(@status.started_at)}
              <span :if={@status.started_at} class="opacity-60">
                ({Format.ago(@status.started_at, @now)})
              </span>
            </dd>
          </div>
        </dl>

        <p :if={@status.state == :stopped} class="mt-4 text-sm opacity-70">
          The daemon is stopped. Counters below are read from the queue on disk.
        </p>
      </section>

      <section :if={@status.counts} class="grid grid-cols-2 gap-4 md:grid-cols-3 xl:grid-cols-5">
        <.stat_card
          :for={{state, {title, icon, tone}} <- @counters}
          id={"count-#{state}"}
          title={title}
          icon={icon}
          tone={tone}
          value={Map.get(@status.counts, state, 0)}
        />
      </section>

      <p :if={is_nil(@status.counts)} id="no-queue" class="text-sm opacity-70">
        No queue database found for this palace yet.
      </p>
    </Layouts.app>
    """
  end
end
