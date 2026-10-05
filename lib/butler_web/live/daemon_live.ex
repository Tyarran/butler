defmodule ButlerWeb.DaemonLive do
  @moduledoc """
  Daemon status page: running state, PID, palace and job counters.

  Refreshes whenever `Butler.Jobs.Watcher` broadcasts a queue change.
  """
  use ButlerWeb, :live_view

  alias Butler.Daemon.Control
  alias Butler.Daemon.Status
  alias Butler.Jobs.Watcher
  alias ButlerWeb.Format

  @confirmed_actions ~w(stop restart)
  @done_messages %{start: "Daemon started", stop: "Daemon stopped", restart: "Daemon restarted"}
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

    socket =
      socket
      |> assign(page_title: "Daemon", counters: @counters)
      |> assign(busy: nil, confirm: nil, output: nil)
      |> load_status()

    {:ok, socket}
  end

  @impl Phoenix.LiveView
  def handle_event("start", _params, %{assigns: %{busy: nil}} = socket),
    do: {:noreply, run_action(socket, :start)}

  def handle_event("ask", %{"action" => action}, %{assigns: %{busy: nil}} = socket)
      when action in @confirmed_actions,
      do: {:noreply, assign(socket, confirm: String.to_existing_atom(action))}

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, confirm: nil)}

  def handle_event("confirm", _params, %{assigns: %{confirm: action, busy: nil}} = socket)
      when action in [:stop, :restart],
      do: {:noreply, socket |> assign(confirm: nil) |> run_action(action)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_async(:control, {:ok, result}, socket) do
    action = socket.assigns.busy
    socket = assign(socket, busy: nil)

    case result do
      {:ok, output} ->
        {:noreply,
         socket
         |> put_flash(:info, @done_messages[action])
         |> assign(output: output)
         |> load_status()}

      {:error, reason} ->
        {:noreply,
         socket
         |> put_flash(:error, error_message(action, reason))
         |> assign(output: error_output(reason))
         |> load_status()}
    end
  end

  def handle_async(:control, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(busy: nil)
     |> put_flash(:error, "The command crashed: #{inspect(reason)}")}
  end

  @impl Phoenix.LiveView
  def handle_info({:queue_changed, _snapshot}, socket), do: {:noreply, load_status(socket)}

  defp run_action(socket, action) do
    opts = Application.get_env(:butler, :control_opts, [])

    socket
    |> assign(busy: action, output: nil)
    |> start_async(:control, fn -> apply(Control, action, [opts]) end)
  end

  defp error_message(action, {:cli, _failure}), do: "Could not #{action} the daemon"

  defp error_message(action, {:timeout, _output}),
    do: "Could not #{action} the daemon: the command timed out"

  defp error_message(_action, :stop_timeout),
    do: "The daemon did not stop in time; it was not started again"

  defp error_message(action, reason),
    do: "Could not #{action} the daemon: #{inspect(reason)}"

  defp error_output({:cli, %{output: output}}), do: output
  defp error_output({:timeout, output}), do: output
  defp error_output(_reason), do: nil

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

        <div id="daemon-controls" class="mt-5 flex flex-wrap gap-2">
          <button
            :if={@status.state == :stopped}
            id="btn-start"
            class="btn btn-success"
            phx-click="start"
            disabled={@busy != nil}
          >
            <.icon name="hero-play" class="size-4" /> Start
          </button>
          <button
            :if={@status.state == :running}
            id="btn-restart"
            class="btn btn-warning"
            phx-click="ask"
            phx-value-action="restart"
            disabled={@busy != nil}
          >
            <.icon name="hero-arrow-path" class="size-4" /> Restart
          </button>
          <button
            :if={@status.state == :running}
            id="btn-stop"
            class="btn btn-error"
            phx-click="ask"
            phx-value-action="stop"
            disabled={@busy != nil}
          >
            <.icon name="hero-stop" class="size-4" /> Stop
          </button>
          <span :if={@busy} class="flex items-center gap-2 text-sm opacity-70">
            <span class="loading loading-spinner loading-sm"></span> {@busy}…
          </span>
        </div>
      </section>

      <.terminal
        :if={@output && @output != ""}
        id="last-output"
        title="mempalace daemon"
        text={@output}
      />

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

      <dialog :if={@confirm} id="confirm-dialog" class="modal modal-open" aria-modal="true">
        <div class="modal-box">
          <h3 class="text-lg font-semibold">
            {if @confirm == :stop, do: "Stop the daemon?", else: "Restart the daemon?"}
          </h3>
          <p class="mt-3 text-sm">
            The daemon waits up to <strong>10 seconds</strong>
            for the running job to finish. If it is still running after that, the job is
            marked <strong>cancelled</strong>
            and is <strong>not resumed automatically</strong>
            when the daemon starts again. Queued jobs stay queued.
          </p>
          <p :if={@confirm == :restart} class="mt-2 text-sm opacity-70">
            Butler will wait for the daemon to stop, then start it again.
          </p>
          <div class="modal-action">
            <button id="confirm-cancel" class="btn" phx-click="cancel">Cancel</button>
            <button id="confirm-ok" class="btn btn-error" phx-click="confirm">
              {if @confirm == :stop, do: "Stop", else: "Restart"}
            </button>
          </div>
        </div>
      </dialog>
    </Layouts.app>
    """
  end
end
