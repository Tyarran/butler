defmodule ButlerWeb.MCPLive do
  @moduledoc """
  MCP proxy page: state of each backend (`full`, `light`), time before the
  next rotation, client sessions, requests, and a forced restart.

  The page only observes `Butler.MCP`; the proxy works without it. It
  refreshes on every `{:mcp_changed, backend}` notification and once a second
  so that the countdown and the request counters stay live.
  """
  use ButlerWeb, :live_view

  alias Butler.MCP
  alias ButlerWeb.Format

  @tick_ms 1_000
  @backends %{"full" => :full, "light" => :light}
  @badge_classes %{
    ready: "badge-success",
    degraded: "badge-warning",
    starting: "badge-info",
    failed: "badge-error"
  }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      MCP.subscribe()
      schedule_tick()
    end

    {:ok, socket |> assign(page_title: "MCP") |> load()}
  end

  @impl Phoenix.LiveView
  def handle_event("restart", %{"backend" => backend}, socket) do
    with {:ok, backend} <- Map.fetch(@backends, backend),
         :ok <- MCP.restart(backend) do
      {:noreply, socket |> put_flash(:info, "Restarting #{backend}") |> load()}
    else
      _error -> {:noreply, put_flash(socket, :error, "Could not restart this backend")}
    end
  end

  @impl Phoenix.LiveView
  def handle_info(:tick, socket) do
    schedule_tick()
    {:noreply, load(socket)}
  end

  def handle_info({:mcp_changed, _backend}, socket), do: {:noreply, load(socket)}

  defp schedule_tick, do: Process.send_after(self(), :tick, @tick_ms)

  defp load(socket) do
    assign(socket, backends: MCP.status(), now_ms: System.system_time(:millisecond))
  end

  defp countdown(nil, _now_ms), do: "—"

  defp countdown(next_rotation_at, now_ms) do
    Format.duration(max(div(next_rotation_at - now_ms, 1_000), 0))
  end

  defp uptime(%{started_at: started_at}, now_ms),
    do: Format.duration(max(div(now_ms - started_at, 1_000), 0))

  defp pid_text(nil), do: "—"
  defp pid_text(%{os_pid: nil}), do: "starting…"
  defp pid_text(%{os_pid: os_pid}), do: Integer.to_string(os_pid)

  defp standby_text(%{standby: nil, starting: starting}) when starting > 0, do: "starting…"
  defp standby_text(%{standby: nil}), do: "—"
  defp standby_text(%{standby: standby}), do: pid_text(standby)

  defp error_text(nil), do: nil
  defp error_text({:exit_status, status}), do: "the process exited with status #{status}"
  defp error_text(:startup_timeout), do: "the process did not complete its handshake in time"
  defp error_text({:executable_not_found, bin}), do: "executable not found: #{bin}"
  defp error_text(other), do: inspect(other)

  defp badge_class(status), do: Map.get(@badge_classes, status, "badge-ghost")

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:mcp} title="MCP">
      <p :if={@backends == []} id="mcp-disabled" class="text-sm opacity-70">
        The MCP proxy is not running (disabled with <code>BUTLER_MCP_ENABLED=false</code>).
      </p>

      <section
        :for={backend <- @backends}
        id={"backend-#{backend.id}"}
        class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm"
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <div class="flex flex-wrap items-center gap-3">
            <h2 class="text-lg font-semibold capitalize">{backend.id}</h2>
            <span
              id={"status-#{backend.id}"}
              class={["badge badge-soft badge-lg", badge_class(backend.status)]}
              data-state={backend.status}
            >
              {backend.status}
            </span>
            <code class="text-xs opacity-60">POST /mcp/{backend.id}</code>
          </div>

          <button
            id={"btn-restart-#{backend.id}"}
            class="btn btn-warning btn-sm"
            phx-click="restart"
            phx-value-backend={backend.id}
            data-confirm={"Restart the #{backend.id} backend now? Requests in flight fail."}
          >
            <.icon name="hero-arrow-path" class="size-4" /> Restart
          </button>
        </div>

        <p
          :if={backend.status == :failed}
          id={"last-error-#{backend.id}"}
          class="mt-3 rounded-field bg-error/10 p-3 text-sm text-error"
        >
          Could not start after {backend.failures} attempts: {error_text(backend.last_error)}.
          Restart to try again.
        </p>

        <dl class="mt-4 grid gap-x-8 gap-y-3 sm:grid-cols-2 lg:grid-cols-4">
          <div>
            <dt class="text-xs uppercase opacity-60">Active process</dt>
            <dd id={"active-#{backend.id}"} class="font-mono text-sm">
              {pid_text(backend.active)}
              <span :if={backend.active} class="opacity-60">
                (up {uptime(backend.active, @now_ms)})
              </span>
            </dd>
          </div>
          <div>
            <dt class="text-xs uppercase opacity-60">Standby process</dt>
            <dd id={"standby-#{backend.id}"} class="font-mono text-sm">{standby_text(backend)}</dd>
          </div>
          <div>
            <dt class="text-xs uppercase opacity-60">Next rotation</dt>
            <dd id={"rotation-#{backend.id}"} class="text-sm tabular-nums">
              {countdown(backend.next_rotation_at, @now_ms)}
              <span class="opacity-60">
                (every {Format.duration(div(backend.idle_rotation_ms, 1_000))} idle)
              </span>
            </dd>
          </div>
          <div>
            <dt class="text-xs uppercase opacity-60">Rotations</dt>
            <dd id={"rotations-#{backend.id}"} class="text-sm tabular-nums">{backend.rotations}</dd>
          </div>
        </dl>

        <div class="mt-5 grid grid-cols-3 gap-4">
          <.stat_card
            id={"sessions-#{backend.id}"}
            title="Client sessions"
            icon="hero-users"
            value={backend.sessions}
          />
          <.stat_card
            id={"requests-#{backend.id}"}
            title="Requests"
            icon="hero-arrows-right-left"
            tone={:info}
            value={backend.requests}
          />
          <.stat_card
            id={"errors-#{backend.id}"}
            title="Errors"
            icon="hero-exclamation-triangle"
            tone={if backend.errors > 0, do: :error, else: :default}
            value={backend.errors}
          />
        </div>
      </section>
    </Layouts.app>
    """
  end
end
