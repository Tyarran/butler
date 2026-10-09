defmodule ButlerWeb.WorkerLive do
  @moduledoc """
  Worker page: status of Butler's serial worker (`idle`, `running`,
  `blocked`, ...), its active job, the job counters and the maintenance flag.

  The worker is `blocked` while the legacy MemPalace Python daemon is alive:
  two writers must never share a palace, so the daemon has to be stopped
  (and write routing set to direct) for Butler to run jobs.

  Refreshes on the worker topic (`{:worker_changed, status}`, delivered by
  `ButlerWeb.MaintenanceHook`) and on queue changes.
  """
  use ButlerWeb, :live_view

  alias Butler.Jobs
  alias Butler.Jobs.Queue
  alias Butler.Palace
  alias Butler.Paths

  @states ~w(queued running succeeded failed cancelled)a

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Queue.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Worker", states: @states)
     |> assign(palace: Palace.path(), queue_path: Paths.queue_path())
     |> load()}
  end

  @impl Phoenix.LiveView
  def handle_info({:worker_changed, _status}, socket), do: {:noreply, load(socket)}
  def handle_info({:job_changed, _job}, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    counts =
      case Jobs.counts() do
        {:ok, counts} -> counts
        {:error, _reason} -> nil
      end

    assign(socket, worker: Jobs.worker_status(), counts: counts)
  end

  defp status_text(:idle), do: "Waiting for a job."
  defp status_text(:running), do: "Running a job."
  defp status_text(:booting), do: "Starting: recovering interrupted jobs."

  defp status_text(:blocked),
    do:
      "Blocked: the legacy MemPalace Python daemon is still running. " <>
        "Stop it (and set write routing to direct) so that Butler can be the only writer."

  defp status_text(:unavailable), do: "The job engine is not running."

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:worker} title="Worker" maintenance={@maintenance}>
      <section class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm">
        <div class="flex flex-wrap items-center gap-3">
          <span id="worker-status"><.status_badge state={@worker.status} class="badge-lg" /></span>
          <span id="worker-status-text" class="text-sm opacity-80">{status_text(@worker.status)}</span>
        </div>

        <dl class="mt-4 grid gap-x-8 gap-y-3 sm:grid-cols-2">
          <div>
            <dt class="text-xs uppercase opacity-60">Active job</dt>
            <dd id="worker-active-job" class="text-sm">
              <.link
                :if={@worker.active_job_id}
                navigate={~p"/jobs/#{@worker.active_job_id}"}
                class="link font-mono"
              >
                {@worker.active_job_id}
              </.link>
              <span :if={!@worker.active_job_id} class="opacity-60">none</span>
            </dd>
          </div>
          <div>
            <dt class="text-xs uppercase opacity-60">Maintenance</dt>
            <dd id="worker-maintenance" class="text-sm">
              {if @maintenance, do: "active", else: "inactive"}
            </dd>
          </div>
          <div>
            <dt class="text-xs uppercase opacity-60">Palace</dt>
            <dd class="break-all font-mono text-sm">{@palace}</dd>
          </div>
          <div>
            <dt class="text-xs uppercase opacity-60">Queue database</dt>
            <dd class="break-all font-mono text-sm">{@queue_path}</dd>
          </div>
        </dl>
      </section>

      <section :if={@counts} id="worker-counts" class="grid gap-4 sm:grid-cols-2 lg:grid-cols-5">
        <.stat_card
          :for={state <- @states}
          id={"count-#{state}"}
          title={Atom.to_string(state)}
          value={Map.get(@counts, state, 0)}
          tone={count_tone(state)}
        />
      </section>
      <p :if={!@counts} id="worker-no-queue" class="text-sm opacity-70">
        The queue database is not available.
      </p>

      <.link navigate={~p"/jobs"} class="btn btn-sm">
        <.icon name="hero-queue-list" class="size-4" /> Jobs
      </.link>
    </Layouts.app>
    """
  end

  defp count_tone(:queued), do: :info
  defp count_tone(:running), do: :warning
  defp count_tone(:succeeded), do: :success
  defp count_tone(:failed), do: :error
  defp count_tone(_state), do: :default
end
