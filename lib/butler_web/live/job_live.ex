defmodule ButlerWeb.JobLive do
  @moduledoc """
  Detail page of a single job: summary, timings, payload, error and result.

  For `mine`-like jobs the result's `stdout` is rendered in a terminal block.
  """
  use ButlerWeb, :live_view

  alias Butler.Daemon.Status
  alias Butler.Jobs.Job
  alias Butler.Jobs.Store
  alias Butler.Jobs.Watcher
  alias ButlerWeb.Format

  @impl Phoenix.LiveView
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Watcher.subscribe()

    {:ok, socket |> assign(page_title: "Job #{String.slice(id, 0, 8)}", id: id) |> load_job()}
  end

  @impl Phoenix.LiveView
  def handle_info({:queue_changed, _snapshot}, socket), do: {:noreply, load_job(socket)}

  defp load_job(socket) do
    job =
      with path when is_binary(path) <- Status.resolve().queue_path,
           {:ok, job} <- Store.get(path, socket.assigns.id) do
        job
      else
        _ -> nil
      end

    assign(socket, job: job, now: DateTime.utc_now())
  end

  # Pretty-printed JSON for maps and lists; strings (e.g. malformed JSON kept
  # raw by the parser) are shown as they are.
  defp pretty(nil), do: nil
  defp pretty(value) when is_binary(value), do: value
  defp pretty(value), do: Jason.encode!(value, pretty: true)

  defp stdout(%Job{result: %{"stdout" => stdout}}) when is_binary(stdout) and stdout != "",
    do: stdout

  defp stdout(%Job{}), do: nil

  defp result_without_stdout(%Job{result: %{} = result}) do
    case Map.delete(result, "stdout") do
      rest when map_size(rest) == 0 -> nil
      rest -> rest
    end
  end

  defp result_without_stdout(%Job{result: result}), do: result

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:jobs} title={if @job, do: "Job", else: "Job not found"}>
      <:actions>
        <.link navigate={~p"/jobs"} class="btn btn-sm">
          <.icon name="hero-arrow-left" class="size-4" /> Jobs
        </.link>
      </:actions>

      <p :if={is_nil(@job)} id="job-not-found" class="text-sm opacity-70">
        No job with id <span class="font-mono">{@id}</span>
        was found in the queue. It may have been purged (the daemon removes finished jobs after 7 days).
      </p>

      <div :if={@job} class="space-y-6">
        <section class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm">
          <div class="flex flex-wrap items-center gap-3">
            <span id="job-state"><.status_badge state={@job.state} class="badge-lg" /></span>
            <span class="badge badge-outline">{@job.kind}</span>
            <span class="break-all font-mono text-sm">{@job.id}</span>
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
          <.terminal id="job-error" title="error" text={pretty(@job.error)} />
        </section>

        <section :if={stdout(@job)} class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">Output</h2>
          <.terminal id="job-stdout" title={"#{@job.kind} stdout"} text={stdout(@job)} />
        </section>

        <section :if={result_without_stdout(@job)} class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">Result</h2>
          <.terminal id="job-result" title="result.json" text={pretty(result_without_stdout(@job))} />
        </section>

        <section class="space-y-2">
          <h2 class="text-sm font-semibold uppercase tracking-wide opacity-70">Payload</h2>
          <.terminal id="job-payload" title="payload.json" text={pretty(@job.payload)} />
        </section>
      </div>
    </Layouts.app>
    """
  end
end
