defmodule ButlerWeb.JobsLive do
  @moduledoc """
  Job queue page: active (queued/running) jobs on top, then recent history.

  Refreshes whenever `Butler.Jobs.Watcher` broadcasts a queue change.
  """
  use ButlerWeb, :live_view

  alias Butler.Daemon.Status
  alias Butler.Jobs.DurationHint
  alias Butler.Jobs.Job
  alias Butler.Jobs.Store
  alias Butler.Jobs.Watcher
  alias ButlerWeb.Format

  @list_limit 200

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Watcher.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Jobs")
     |> stream_configure(:history, dom_id: &"job-#{&1.id}")
     |> load_jobs()}
  end

  @impl Phoenix.LiveView
  def handle_info({:queue_changed, _snapshot}, socket), do: {:noreply, load_jobs(socket)}

  defp load_jobs(socket) do
    now = DateTime.utc_now()

    case fetch_jobs() do
      {:ok, jobs} ->
        {active, history} = Enum.split_with(jobs, &Job.active?/1)
        hints = Map.new(active, &{&1.id, DurationHint.hint(&1, jobs, now)})

        socket
        |> assign(queue?: true, active: active, hints: hints, now: now, empty?: jobs == [])
        |> stream(:history, history, reset: true)

      {:error, _reason} ->
        socket
        |> assign(queue?: false, active: [], hints: %{}, now: now, empty?: true)
        |> stream(:history, [], reset: true)
    end
  end

  defp fetch_jobs do
    case Status.resolve().queue_path do
      nil -> {:error, :not_found}
      path -> Store.list(path, limit: @list_limit)
    end
  end

  @doc false
  @spec summary(Job.t()) :: String.t() | nil
  def summary(%Job{kind: "mine", payload: %{"source" => source}}), do: source
  def summary(%Job{kind: "sweep", payload: %{"target" => target}}), do: target
  def summary(%Job{kind: "mcp_tool", payload: %{"name" => name}}), do: name
  def summary(%Job{}), do: nil

  attr :id, :string, required: true
  attr :job, :any, required: true
  attr :hint, :string, default: nil
  attr :now, :any, required: true

  defp job_row(assigns) do
    ~H"""
    <tr id={@id}>
      <td class="font-mono text-xs">{String.slice(@job.id, 0, 8)}</td>
      <td>{@job.kind}</td>
      <td><.status_badge state={@job.state} /></td>
      <td class="max-w-xs truncate text-xs opacity-80" title={summary(@job)}>{summary(@job)}</td>
      <td class="whitespace-nowrap text-sm">{Format.ago(@job.created_at, @now)}</td>
      <td class="whitespace-nowrap text-sm tabular-nums">
        {Format.duration(Job.duration(@job, @now))}
        <div :if={@hint} class="text-xs opacity-60">{@hint}</div>
      </td>
      <td class="text-center tabular-nums">{@job.attempts}</td>
    </tr>
    """
  end

  defp job_table_head(assigns) do
    ~H"""
    <tr>
      <th>ID</th>
      <th>Kind</th>
      <th>State</th>
      <th>Target</th>
      <th>Created</th>
      <th>Duration</th>
      <th class="text-center">Attempts</th>
    </tr>
    """
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:jobs} title="Jobs">
      <p :if={!@queue?} class="text-sm opacity-70">No queue database found for this palace yet.</p>

      <section :if={@queue?} class="space-y-2">
        <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">
          Active <span class="badge badge-sm">{length(@active)}</span>
        </h2>
        <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
          <table class="table">
            <thead><.job_table_head /></thead>
            <tbody id="active-jobs">
              <.job_row
                :for={job <- @active}
                id={"job-#{job.id}"}
                job={job}
                hint={@hints[job.id]}
                now={@now}
              />
              <tr :if={@active == []}>
                <td colspan="7" class="text-center text-sm opacity-60">No active jobs</td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>

      <section :if={@queue?} class="space-y-2">
        <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">History</h2>
        <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
          <table class="table">
            <thead><.job_table_head /></thead>
            <tbody id="job-history" phx-update="stream">
              <.job_row :for={{dom_id, job} <- @streams.history} id={dom_id} job={job} now={@now} />
            </tbody>
          </table>
        </div>
        <p :if={@empty?} class="text-sm opacity-60">No jobs yet.</p>
      </section>
    </Layouts.app>
    """
  end
end
