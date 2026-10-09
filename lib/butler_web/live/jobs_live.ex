defmodule ButlerWeb.JobsLive do
  @moduledoc """
  Job queue page: active (queued/running) jobs first, then recent history.

  The list is a LiveView stream kept up to date by the queue's
  `{:job_changed, job}` PubSub events (no polling). Filters live in the URL
  (`?state=&kind=`). Queued and running jobs can be cancelled; failed and
  cancelled jobs can be retried (a new job is enqueued), after a confirmation
  for kinds that are not idempotent (`diary_write`, `mcp_tool`, maintenance).
  """
  use ButlerWeb, :live_view

  alias Butler.Jobs
  alias Butler.Jobs.DurationHint
  alias Butler.Jobs.Job
  alias Butler.Jobs.Kinds
  alias Butler.Jobs.Queue
  alias ButlerWeb.Format

  @list_limit 200
  @states ~w(queued running succeeded failed cancelled)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket), do: Queue.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Jobs", states: @states, filters: %{state: nil, kind: nil})
     |> assign(kinds: [], counts: nil, history: [], confirm_retry: nil, queue?: true)
     |> assign(now: DateTime.utc_now())
     |> stream_configure(:jobs, dom_id: &"job-#{&1.id}")}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    kinds = available_kinds()

    filters = %{
      state: if(params["state"] in @states, do: params["state"]),
      kind: if(params["kind"] in kinds, do: params["kind"])
    }

    {:noreply,
     socket |> assign(filters: filters, kinds: kinds, now: DateTime.utc_now()) |> load_jobs()}
  end

  @impl Phoenix.LiveView
  def handle_info({:job_changed, %Job{} = job}, socket) do
    socket =
      socket
      |> assign(kinds: available_kinds(), counts: counts(), now: DateTime.utc_now())
      |> track_history(job)

    {:noreply,
     if(matches?(job, socket.assigns.filters), do: put_job(socket, job), else: drop(socket, job))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("cancel", %{"id" => id}, socket) do
    case Jobs.cancel(id) do
      {:ok, _job} -> {:noreply, put_flash(socket, :info, "Cancelling job #{short(id)}.")}
      {:error, reason} -> {:noreply, put_flash(socket, :error, cancel_error(reason))}
    end
  end

  def handle_event("retry", %{"id" => id}, socket) do
    with {:ok, %Job{} = job} <- Jobs.get(id),
         true <- Jobs.retryable?(job) do
      if Kinds.idempotent?(job.kind),
        do: {:noreply, retry(socket, job)},
        else: {:noreply, assign(socket, confirm_retry: job)}
    else
      _ -> {:noreply, put_flash(socket, :error, "That job cannot be retried.")}
    end
  end

  def handle_event("confirm_retry", _params, %{assigns: %{confirm_retry: %Job{} = job}} = socket),
    do: {:noreply, socket |> assign(confirm_retry: nil) |> retry(job)}

  def handle_event("cancel_retry", _params, socket),
    do: {:noreply, assign(socket, confirm_retry: nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp retry(socket, job) do
    case Jobs.retry(job) do
      {:ok, new_job, _outcome} ->
        put_flash(socket, :info, "Job #{short(new_job.id)} queued again.")

      {:error, reason} ->
        put_flash(socket, :error, "Could not retry: #{inspect(reason)}")
    end
  end

  defp cancel_error(:job_not_found), do: "Job not found."
  defp cancel_error(:not_cancellable), do: "That job already finished."
  defp cancel_error(reason), do: "Could not cancel: #{inspect(reason)}"

  # -- Loading -------------------------------------------------------------------

  defp load_jobs(socket) do
    filters = socket.assigns.filters

    case Jobs.list(state: state_atom(filters.state), kind: filters.kind) do
      {:ok, jobs} ->
        history = history(filters, jobs)

        socket
        |> assign(queue?: true, counts: counts(), history: history)
        |> stream(:jobs, Enum.map(jobs, &row(&1, history)), reset: true)

      {:error, _reason} ->
        socket
        |> assign(queue?: false, counts: nil, history: [])
        |> stream(:jobs, [], reset: true)
    end
  end

  # Recent jobs used for duration hints, whatever the filters.
  defp history(%{state: nil, kind: nil}, jobs), do: jobs

  defp history(_filters, fallback) do
    case Jobs.list() do
      {:ok, all} -> all
      {:error, _reason} -> fallback
    end
  end

  defp counts do
    case Jobs.counts() do
      {:ok, counts} -> counts
      {:error, _reason} -> nil
    end
  end

  defp available_kinds do
    case Jobs.kinds() do
      {:ok, kinds} -> kinds
      {:error, _reason} -> []
    end
  end

  defp track_history(socket, %Job{state: :succeeded} = job),
    do: assign(socket, history: Enum.take([job | socket.assigns.history], @list_limit))

  defp track_history(socket, _job), do: socket

  defp put_job(socket, job) do
    socket
    |> assign(queue?: true)
    |> stream_insert(:jobs, row(job, socket.assigns.history), at: 0, limit: @list_limit)
  end

  defp drop(socket, job), do: stream_delete(socket, :jobs, %{id: job.id})

  defp matches?(job, %{state: state, kind: kind}) do
    (is_nil(state) or Atom.to_string(job.state) == state) and (is_nil(kind) or job.kind == kind)
  end

  # A stream item: the job plus its duration hint (computed once per update).
  defp row(%Job{} = job, history),
    do: %{id: job.id, job: job, hint: DurationHint.hint(job, history)}

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

  defp short(id), do: String.slice(id, 0, 8)

  @doc false
  @spec summary(Job.t()) :: String.t() | nil
  def summary(%Job{kind: "mine", payload: %{"source" => source}}), do: source
  def summary(%Job{kind: "sweep", payload: %{"target" => target}}), do: target
  # The payload of diary_write / mcp_tool is verbatim user content: never shown in lists.
  def summary(%Job{}), do: nil

  attr :id, :string, required: true
  attr :job, :any, required: true
  attr :hint, :string, default: nil
  attr :now, :any, required: true

  defp job_row(assigns) do
    ~H"""
    <tr id={@id}>
      <td class="font-mono text-xs">
        <.link navigate={~p"/jobs/#{@job.id}"} class="link link-hover">
          {short(@job.id)}
        </.link>
      </td>
      <td>{@job.kind}</td>
      <td><.status_badge state={@job.state} /></td>
      <td class="max-w-xs truncate text-xs opacity-80" title={summary(@job)}>{summary(@job)}</td>
      <td class="whitespace-nowrap text-sm">{Format.ago(@job.created_at, @now)}</td>
      <td class="whitespace-nowrap text-sm tabular-nums">
        {Format.duration(Job.duration(@job, @now))}
        <div :if={@hint} class="text-xs opacity-60">{@hint}</div>
      </td>
      <td class="text-center tabular-nums">{@job.attempts}</td>
      <td class="whitespace-nowrap text-right">
        <button
          :if={Jobs.cancellable?(@job)}
          id={"cancel-#{@job.id}"}
          class="btn btn-xs btn-ghost text-error"
          phx-click="cancel"
          phx-value-id={@job.id}
        >
          <.icon name="hero-x-mark" class="size-4" /> Cancel
        </button>
        <button
          :if={Jobs.retryable?(@job)}
          id={"retry-#{@job.id}"}
          class="btn btn-xs btn-ghost"
          phx-click="retry"
          phx-value-id={@job.id}
        >
          <.icon name="hero-arrow-path" class="size-4" /> Retry
        </button>
      </td>
    </tr>
    """
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:jobs} title="Jobs" maintenance={@maintenance}>
      <p :if={!@queue?} id="queue-unavailable" class="text-sm opacity-70">
        The job queue is not available.
      </p>

      <div :if={@queue?} id="job-counts" class="flex flex-wrap gap-2 text-sm">
        <span :for={state <- @states} class="badge badge-ghost gap-1">
          {state}
          <span id={"jobs-count-#{state}"} class="tabular-nums">
            {if @counts, do: Map.get(@counts, String.to_existing_atom(state), 0), else: "—"}
          </span>
        </span>
      </div>

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
        <div class="overflow-x-auto rounded-box border border-base-300 bg-base-100">
          <table class="table">
            <thead>
              <tr>
                <th>ID</th>
                <th>Kind</th>
                <th>State</th>
                <th>Target</th>
                <th>Created</th>
                <th>Duration</th>
                <th class="text-center">Attempts</th>
                <th></th>
              </tr>
            </thead>
            <tbody id="jobs" phx-update="stream">
              <tr id="jobs-empty" class="hidden only:table-row">
                <td colspan="8" class="text-center text-sm opacity-60">No jobs yet</td>
              </tr>
              <.job_row
                :for={{dom_id, item} <- @streams.jobs}
                id={dom_id}
                job={item.job}
                hint={item.hint}
                now={@now}
              />
            </tbody>
          </table>
        </div>
      </section>

      <dialog
        :if={@confirm_retry}
        id="retry-dialog"
        class="modal modal-open"
        aria-modal="true"
      >
        <div class="modal-box">
          <h3 class="text-lg font-semibold">Run {@confirm_retry.kind} again?</h3>
          <p class="mt-3 text-sm">
            A <code>{@confirm_retry.kind}</code>
            job is not idempotent: running it again repeats its effect
            (a write, or a maintenance operation on the palace).
          </p>
          <div class="modal-action">
            <button id="retry-cancel" class="btn" phx-click="cancel_retry">Cancel</button>
            <button id="retry-confirm" class="btn btn-warning" phx-click="confirm_retry">
              Retry
            </button>
          </div>
        </div>
      </dialog>
    </Layouts.app>
    """
  end
end
