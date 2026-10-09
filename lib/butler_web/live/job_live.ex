defmodule ButlerWeb.JobLive do
  @moduledoc """
  Detail page of a single job: summary, timings, queue position, output,
  error and result.

  Live: the page follows the queue's `{:job_changed, job}` events, and while
  the job runs the worker's output lines (`{:job_output, id, line}` on
  `butler:job:<id>`) are streamed into a terminal block. Once the job is
  finished the persisted output tail (`output_tail` of the result or of the
  error) is shown instead.

  The payload of `diary_write` and `mcp_tool` jobs is verbatim user content:
  it is never shown.
  """
  use ButlerWeb, :live_view

  alias Butler.Jobs
  alias Butler.Jobs.Job
  alias Butler.Jobs.Kinds
  alias Butler.Jobs.Queue
  alias Butler.Jobs.Worker
  alias ButlerWeb.Format

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Queue.subscribe()
      Phoenix.PubSub.subscribe(Butler.PubSub, Worker.job_topic(id))
    end

    {:ok,
     socket
     |> assign(page_title: "Job #{String.slice(id, 0, 8)}", id: id, line_no: 0)
     |> assign(confirm_retry: false, retention_days: Queue.retention_days())
     |> stream(:lines, [])
     |> load_job()}
  end

  @impl Phoenix.LiveView
  def handle_info({:job_changed, %Job{id: id}}, %{assigns: %{id: id}} = socket),
    do: {:noreply, load_job(socket)}

  # Another job moved: the position of this one may have changed.
  def handle_info({:job_changed, %Job{}}, %{assigns: %{job: %Job{state: :queued}}} = socket),
    do: {:noreply, load_job(socket)}

  def handle_info({:job_output, id, line}, %{assigns: %{id: id}} = socket) do
    line_no = socket.assigns.line_no + 1

    {:noreply,
     socket |> assign(line_no: line_no) |> stream_insert(:lines, %{id: line_no, text: line})}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_event("cancel", _params, socket) do
    case Jobs.cancel(socket.assigns.id) do
      {:ok, _job} ->
        {:noreply, put_flash(socket, :info, "Cancelling the job.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not cancel: #{inspect(reason)}")}
    end
  end

  def handle_event("retry", _params, %{assigns: %{job: %Job{} = job}} = socket) do
    cond do
      not Jobs.retryable?(job) ->
        {:noreply, put_flash(socket, :error, "That job cannot be retried.")}

      Kinds.idempotent?(job.kind) ->
        {:noreply, retry(socket, job)}

      true ->
        {:noreply, assign(socket, confirm_retry: true)}
    end
  end

  def handle_event("confirm_retry", _params, %{assigns: %{job: %Job{} = job}} = socket),
    do: {:noreply, socket |> assign(confirm_retry: false) |> retry(job)}

  def handle_event("cancel_retry", _params, socket),
    do: {:noreply, assign(socket, confirm_retry: false)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  defp retry(socket, job) do
    case Jobs.retry(job) do
      {:ok, new_job, _outcome} -> push_navigate(socket, to: ~p"/jobs/#{new_job.id}")
      {:error, reason} -> put_flash(socket, :error, "Could not retry: #{inspect(reason)}")
    end
  end

  defp load_job(socket) do
    job =
      case Jobs.get(socket.assigns.id) do
        {:ok, job} -> job
        {:error, _reason} -> nil
      end

    position = if match?(%Job{state: :queued}, job), do: Jobs.positions()[job.id]
    assign(socket, job: job, position: position, now: DateTime.utc_now())
  end

  # Pretty-printed JSON for maps and lists; strings (e.g. malformed JSON kept
  # raw by the parser) are shown as they are.
  defp pretty(nil), do: nil
  defp pretty(value) when is_binary(value), do: value
  defp pretty(value), do: Jason.encode!(value, pretty: true)

  # The output tail persisted with the outcome of a CLI job.
  @doc false
  @spec output_tail(Job.t()) :: String.t() | nil
  def output_tail(%Job{} = job) do
    Enum.find_value([job.result, job.error], fn
      %{"output_tail" => tail} when is_binary(tail) and tail != "" -> tail
      _other -> nil
    end)
  end

  defp result_without_tail(%Job{result: %{} = result}) do
    case Map.delete(result, "output_tail") do
      rest when map_size(rest) == 0 -> nil
      rest -> rest
    end
  end

  defp result_without_tail(%Job{result: result}), do: result

  defp error_without_tail(%Job{error: %{} = error}), do: Map.delete(error, "output_tail")
  defp error_without_tail(%Job{error: error}), do: error

  defp live_output?(%Job{} = job, line_no),
    do: Job.active?(job) or (line_no > 0 and is_nil(output_tail(job)))

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      active={:jobs}
      title={if @job, do: "Job", else: "Job not found"}
      maintenance={@maintenance}
    >
      <:actions>
        <button
          :if={@job && Jobs.cancellable?(@job)}
          id="cancel-job"
          class="btn btn-sm btn-error btn-soft"
          phx-click="cancel"
        >
          <.icon name="hero-x-mark" class="size-4" /> Cancel
        </button>
        <button
          :if={@job && Jobs.retryable?(@job)}
          id="retry-job"
          class="btn btn-sm"
          phx-click="retry"
        >
          <.icon name="hero-arrow-path" class="size-4" /> Retry
        </button>
        <.link navigate={~p"/jobs"} class="btn btn-sm">
          <.icon name="hero-arrow-left" class="size-4" /> Jobs
        </.link>
      </:actions>

      <p :if={is_nil(@job)} id="job-not-found" class="text-sm opacity-70">
        No job with id <span class="font-mono">{@id}</span>
        was found in the queue. It may have been purged (finished jobs are removed after {@retention_days} days).
      </p>

      <div :if={@job} class="space-y-6">
        <section class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm">
          <div class="flex flex-wrap items-center gap-3">
            <span id="job-state"><.status_badge state={@job.state} class="badge-lg" /></span>
            <span class="badge badge-outline">{@job.kind}</span>
            <span class="break-all font-mono text-sm">{@job.id}</span>
            <span :if={@position} id="job-position" class="badge badge-info badge-soft">
              #{@position} in queue
            </span>
          </div>

          <dl class="mt-4 grid gap-x-8 gap-y-3 sm:grid-cols-2 lg:grid-cols-4">
            <div>
              <dt class="text-xs uppercase opacity-60">Created</dt>
              <dd class="text-sm">{Format.datetime(@job.created_at)}</dd>
            </div>
            <div>
              <dt class="text-xs uppercase opacity-60">Started</dt>
              <dd class="text-sm">{Format.datetime(@job.started_at)}</dd>
            </div>
            <div>
              <dt class="text-xs uppercase opacity-60">Finished</dt>
              <dd class="text-sm">{Format.datetime(@job.finished_at)}</dd>
            </div>
            <div>
              <dt class="text-xs uppercase opacity-60">Duration</dt>
              <dd id="job-duration" class="text-sm tabular-nums">
                {Format.duration(Job.duration(@job, @now))}
              </dd>
            </div>
            <div>
              <dt class="text-xs uppercase opacity-60">Attempts</dt>
              <dd id="job-attempts" class="text-sm tabular-nums">{@job.attempts}</dd>
            </div>
            <div>
              <dt class="text-xs uppercase opacity-60">Priority</dt>
              <dd id="job-priority" class="text-sm tabular-nums">{@job.priority}</dd>
            </div>
            <div class="sm:col-span-2">
              <dt class="text-xs uppercase opacity-60">Dedupe key</dt>
              <dd id="job-dedupe" class="break-all font-mono text-sm">{@job.dedupe_key || "—"}</dd>
            </div>
          </dl>
        </section>

        <section :if={@job.error} class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide text-error">Error</h2>
          <.terminal id="job-error" title="error" text={pretty(error_without_tail(@job))} />
        </section>

        <section :if={live_output?(@job, @line_no)} class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">Live output</h2>
          <.terminal id="job-live-output" title={"#{@job.kind} output"}>
            <div id="job-live-lines" phx-update="stream">
              <div :for={{dom_id, line} <- @streams.lines} id={dom_id}>{line.text}</div>
            </div>
          </.terminal>
        </section>

        <section :if={output_tail(@job)} class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">Output (tail)</h2>
          <.terminal id="job-tail" title={"#{@job.kind} output"} text={output_tail(@job)} />
        </section>

        <section :if={result_without_tail(@job)} class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">Result</h2>
          <.terminal id="job-result" title="result.json" text={pretty(result_without_tail(@job))} />
        </section>

        <section class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">Payload</h2>
          <p
            :if={Kinds.sensitive_payload?(@job.kind)}
            id="job-payload-hidden"
            class="text-sm opacity-70"
          >
            Hidden: the payload of {@job.kind} jobs is verbatim content and is never shown.
          </p>
          <.terminal
            :if={!Kinds.sensitive_payload?(@job.kind)}
            id="job-payload"
            title="payload.json"
            text={pretty(@job.payload)}
          />
        </section>
      </div>

      <dialog :if={@confirm_retry} id="retry-dialog" class="modal modal-open" aria-modal="true">
        <div class="modal-box">
          <h3 class="text-lg font-semibold">Run {@job.kind} again?</h3>
          <p class="mt-3 text-sm">
            A <code>{@job.kind}</code> job is not idempotent: running it again repeats its effect
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
