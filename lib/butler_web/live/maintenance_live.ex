defmodule ButlerWeb.MaintenanceLive do
  @moduledoc """
  Maintenance commands (`repair`, `compress`, `migrate-wings`).

  Nothing runs from this page: a confirmed request is queued like any other
  job (`Butler.Commands.Submit.maintenance/2`) and the serial worker runs it
  when its turn comes. While it runs, Butler is in maintenance mode: the MCP
  proxy refuses every request and the global banner is shown. The page lists
  the queued and running maintenance jobs with their queue position.
  """
  use ButlerWeb, :live_view

  alias Butler.Commands.Submit
  alias Butler.Jobs
  alias Butler.Jobs.Job
  alias Butler.Jobs.Kinds
  alias Butler.Jobs.Queue

  @commands [
    {"repair", "Repair", "mempalace repair", "Rebuilds the palace index. Can take a long time."},
    {"compress", "Compress", "mempalace compress", "Compresses the drawers of the palace."},
    {"migrate-wings", "Migrate wings", "mempalace migrate-wings", "Migrates wing names."}
  ]

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Queue.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Maintenance", commands: @commands, confirm: nil, result: nil)
     |> assign(positions: %{}, active_count: 0)
     |> stream_configure(:active, dom_id: &"maintenance-job-#{&1.id}")
     |> load_active()}
  end

  @impl Phoenix.LiveView
  def handle_event("ask", %{"command" => command, "mode" => mode}, socket)
      when mode in ["run", "dry"] do
    if command in Kinds.maintenance_kinds(),
      do: {:noreply, assign(socket, confirm: {command, mode == "dry"})},
      else: {:noreply, socket}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, confirm: nil)}

  def handle_event("confirm", _params, %{assigns: %{confirm: {command, dry_run?}}} = socket) do
    result = Submit.maintenance(command, dry_run: dry_run?)

    {:noreply, socket |> assign(confirm: nil, result: result) |> load_active()}
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  # Any job may move the queue positions.
  def handle_info({:job_changed, %Job{}}, socket), do: {:noreply, load_active(socket)}

  def handle_info(_message, socket), do: {:noreply, socket}

  defp load_active(socket) do
    # One query per maintenance kind (the store lists active jobs first), so
    # other kinds can never push a maintenance job out of the limit.
    jobs =
      Kinds.maintenance_kinds()
      |> Enum.flat_map(&active_of_kind/1)
      |> Enum.sort_by(& &1.created_at, :desc)

    socket
    |> assign(positions: Jobs.positions(), active_count: length(jobs))
    |> stream(:active, jobs, reset: true)
  end

  defp active_of_kind(kind) do
    case Jobs.list(kind: kind, limit: 500) do
      {:ok, jobs} -> Enum.filter(jobs, &Job.active?/1)
      {:error, _reason} -> []
    end
  end

  defp label(command) do
    {_kind, label, _cli, _desc} = List.keyfind(@commands, command, 0)
    label
  end

  defp cli(command) do
    {_kind, _label, cli, _desc} = List.keyfind(@commands, command, 0)
    cli
  end

  attr :result, :any, default: nil
  attr :positions, :map, default: %{}

  defp submit_result(assigns) do
    ~H"""
    <div :if={@result} id="maintenance-result">
      <%= case @result do %>
        <% {:ok, job} -> %>
          <div id="maintenance-queued" role="alert" class="alert alert-success alert-soft">
            <.icon name="hero-check-circle" class="size-5" />
            <span>
              Queued: <.link navigate={~p"/jobs/#{job.id}"} class="link font-mono">{job.id}</.link>
              <span :if={@positions[job.id]} id="maintenance-queued-position">
                (#{@positions[job.id]} in queue)
              </span>
            </span>
          </div>
        <% {:error, {:duplicate, job}} -> %>
          <div id="maintenance-duplicate" role="alert" class="alert alert-warning alert-soft">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>
              An identical job is already queued or running:
              <.link navigate={~p"/jobs/#{job.id}"} class="link font-mono">{job.id}</.link>
            </span>
          </div>
        <% {:error, other} -> %>
          <div id="maintenance-error" role="alert" class="alert alert-error alert-soft">
            <.icon name="hero-x-circle" class="size-5" />
            <span>Could not queue the job: {inspect(other)}</span>
          </div>
      <% end %>
    </div>
    """
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:maintenance} title="Maintenance" maintenance={@maintenance}>
      <div role="alert" class="alert alert-warning alert-soft">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>
          These commands are queued, never run from this page. When one runs, Butler enters maintenance
          mode: the MCP proxy refuses every request (dry runs included) until the job ends.
        </span>
      </div>

      <section class="grid gap-4 md:grid-cols-3">
        <div
          :for={{kind, label, cli, description} <- @commands}
          class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm"
        >
          <h2 class="text-lg font-semibold">{label}</h2>
          <p class="mt-1 font-mono text-xs opacity-60">{cli}</p>
          <p class="mt-2 text-sm opacity-80">{description}</p>
          <div class="mt-4 flex gap-2">
            <button
              id={"dry-#{kind}"}
              class="btn btn-sm"
              phx-click="ask"
              phx-value-command={kind}
              phx-value-mode="dry"
            >
              Dry run
            </button>
            <button
              id={"run-#{kind}"}
              class="btn btn-sm btn-error"
              phx-click="ask"
              phx-value-command={kind}
              phx-value-mode="run"
            >
              Run
            </button>
          </div>
        </div>
      </section>

      <.submit_result result={@result} positions={@positions} />

      <section class="space-y-2">
        <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
          Queued and running <span class="badge badge-sm">{@active_count}</span>
        </h2>
        <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
          <table class="table">
            <thead>
              <tr>
                <th>ID</th>
                <th>Kind</th>
                <th>State</th>
                <th>Position</th>
              </tr>
            </thead>
            <tbody id="maintenance-jobs" phx-update="stream">
              <tr id="maintenance-empty" class="hidden only:table-row">
                <td colspan="4" class="text-center text-sm opacity-60">
                  No maintenance job queued
                </td>
              </tr>
              <tr :for={{dom_id, job} <- @streams.active} id={dom_id}>
                <td class="font-mono text-xs">
                  <.link navigate={~p"/jobs/#{job.id}"} class="link link-hover">
                    {String.slice(job.id, 0, 8)}
                  </.link>
                </td>
                <td>{job.kind}{if match?(%{"dry_run" => true}, job.payload), do: " (dry run)"}</td>
                <td><.status_badge state={job.state} /></td>
                <td class="tabular-nums">
                  <%= cond do %>
                    <% job.state == :running -> %>
                      running
                    <% @positions[job.id] -> %>
                      #{@positions[job.id]}
                    <% true -> %>
                      —
                  <% end %>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <dialog :if={@confirm} id="confirm-dialog" class="modal modal-open" aria-modal="true">
        <div class="modal-box">
          <% {command, dry_run?} = @confirm %>
          <h3 class="text-lg font-semibold">
            Queue {label(command)}{if dry_run?, do: " (dry run)"}?
          </h3>
          <p class="mt-3 text-sm">
            The job runs <code>{cli(command)}{if dry_run?, do: " --dry-run"}</code>
            after the jobs ahead of it. While it runs,
            <strong>the MCP proxy is in maintenance mode</strong>
            and refuses every request.
          </p>
          <p :if={!dry_run?} class="mt-2 text-sm text-error">
            This can modify your palace and cannot be undone.
          </p>
          <div class="modal-action">
            <button id="confirm-cancel" class="btn" phx-click="cancel">Cancel</button>
            <button id="confirm-ok" class="btn btn-error" phx-click="confirm">Queue the job</button>
          </div>
        </div>
      </dialog>
    </Layouts.app>
    """
  end
end
