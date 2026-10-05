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
  @states ~w(queued running succeeded failed cancelled)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Watcher.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Jobs", states: @states, filters: %{state: nil, kind: nil})
     |> stream_configure(:history, dom_id: &"job-#{&1.id}")}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    kinds = available_kinds()

    filters = %{
      state: if(params["state"] in @states, do: params["state"]),
      kind: if(params["kind"] in kinds, do: params["kind"])
    }

    {:noreply, socket |> assign(filters: filters, kinds: kinds) |> load_jobs()}
  end

  @impl Phoenix.LiveView
  def handle_info({:queue_changed, _snapshot}, socket) do
    {:noreply, socket |> assign(kinds: available_kinds()) |> load_jobs()}
  end

  defp load_jobs(socket) do
    now = DateTime.utc_now()
    filters = socket.assigns.filters

    case fetch_jobs(filters) do
      {:ok, jobs, all} ->
        {active, history} = Enum.split_with(jobs, &Job.active?/1)
        hints = Map.new(active, &{&1.id, DurationHint.hint(&1, all, now)})

        socket
        |> assign(queue?: true, active: active, hints: hints, now: now, empty?: jobs == [])
        |> stream(:history, history, reset: true)

      {:error, _reason} ->
        socket
        |> assign(queue?: false, active: [], hints: %{}, now: now, empty?: true)
        |> stream(:history, [], reset: true)
    end
  end

  # Returns the filtered jobs and the unfiltered recent history (used for hints).
  defp fetch_jobs(filters) do
    with path when is_binary(path) <- Status.resolve().queue_path,
         {:ok, jobs} <-
           Store.list(path,
             state: state_atom(filters.state),
             kind: filters.kind,
             limit: @list_limit
           ) do
      all = if filters == %{state: nil, kind: nil}, do: jobs, else: unfiltered(path, jobs)
      {:ok, jobs, all}
    else
      nil -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp unfiltered(path, fallback) do
    case Store.list(path, limit: @list_limit) do
      {:ok, all} -> all
      {:error, _reason} -> fallback
    end
  end

  defp available_kinds do
    with path when is_binary(path) <- Status.resolve().queue_path,
         {:ok, kinds} <- Store.kinds(path) do
      kinds
    else
      _ -> []
    end
  end

  # @states is a fixed whitelist, so the atoms already exist.
  defp state_atom(nil), do: nil
  defp state_atom(state), do: String.to_existing_atom(state)

  defp filter_path(filters, changes) do
    params =
      filters
      |> Map.merge(changes)
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    ~p"/jobs?#{params}"
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

      <div :if={@queue?} id="job-filters" class="space-y-2">
        <div class="flex flex-wrap items-center gap-2">
          <span class="w-12 text-xs uppercase opacity-60">State</span>
          <div class="join">
            <.link
              id="filter-state-all"
              patch={filter_path(@filters, %{state: nil})}
              class={["btn btn-sm join-item", is_nil(@filters.state) && "btn-active"]}
            >
              All
            </.link>
            <.link
              :for={state <- @states}
              id={"filter-state-#{state}"}
              patch={filter_path(@filters, %{state: state})}
              class={["btn btn-sm join-item", @filters.state == state && "btn-active"]}
            >
              {state}
            </.link>
          </div>
        </div>
        <div class="flex flex-wrap items-center gap-2">
          <span class="w-12 text-xs uppercase opacity-60">Kind</span>
          <div class="join">
            <.link
              id="filter-kind-all"
              patch={filter_path(@filters, %{kind: nil})}
              class={["btn btn-sm join-item", is_nil(@filters.kind) && "btn-active"]}
            >
              All
            </.link>
            <.link
              :for={kind <- @kinds}
              id={"filter-kind-#{kind}"}
              patch={filter_path(@filters, %{kind: kind})}
              class={["btn btn-sm join-item", @filters.kind == kind && "btn-active"]}
            >
              {kind}
            </.link>
          </div>
        </div>
      </div>

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
