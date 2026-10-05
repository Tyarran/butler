defmodule ButlerWeb.MaintenanceLive do
  @moduledoc """
  Direct maintenance commands (`repair`, `compress`, `migrate-wings`).

  These commands need the daemon stopped. Each run goes through
  `Butler.Commands.Direct` (guard, stop, command, restart); its output is
  streamed live into a terminal block.
  """
  use ButlerWeb, :live_view

  alias Butler.Commands.Direct

  @commands %{
    "repair" =>
      {:repair, "Repair", "mempalace repair", "Rebuilds the palace index. Can take a long time."},
    "compress" =>
      {:compress, "Compress", "mempalace compress", "Compresses the drawers of the palace."},
    "migrate_wings" =>
      {:migrate_wings, "Migrate wings", "mempalace migrate-wings", "Migrates wing names."}
  }
  @command_order ~w(repair compress migrate_wings)

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Maintenance", commands: @commands, order: @command_order)
     |> assign(confirm: nil, run_id: Direct.running(), steps: [], result: nil, restart: nil)
     |> assign(refusal: nil, error: nil, line_no: 0, run_label: nil)
     |> stream(:lines, [])}
  end

  @impl Phoenix.LiveView
  def handle_event("ask", %{"command" => command, "mode" => mode}, socket)
      when is_map_key(@commands, command) and mode in ["run", "dry"] do
    {:noreply, assign(socket, confirm: {command, mode == "dry"})}
  end

  def handle_event("cancel", _params, socket), do: {:noreply, assign(socket, confirm: nil)}

  def handle_event("confirm", _params, %{assigns: %{confirm: {command, dry_run?}}} = socket) do
    {atom, label, _cli, _desc} = Map.fetch!(@commands, command)
    run_id = Direct.new_run_id()
    :ok = Phoenix.PubSub.subscribe(Butler.PubSub, Direct.topic(run_id))

    opts =
      :butler
      |> Application.get_env(:direct_opts, [])
      |> Keyword.merge(run_id: run_id, dry_run: dry_run?)

    socket =
      socket
      |> assign(
        confirm: nil,
        steps: [],
        result: nil,
        restart: nil,
        refusal: nil,
        error: nil,
        line_no: 0
      )
      |> stream(:lines, [], reset: true)

    case Direct.start_run(atom, opts) do
      {:ok, ^run_id} ->
        {:noreply,
         assign(socket,
           run_id: run_id,
           run_label: label <> if(dry_run?, do: " (dry run)", else: "")
         )}

      {:error, reason} ->
        Phoenix.PubSub.unsubscribe(Butler.PubSub, Direct.topic(run_id))
        {:noreply, refuse(socket, reason)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl Phoenix.LiveView
  def handle_info({:direct, run_id, event}, %{assigns: %{run_id: run_id}} = socket) do
    {:noreply, apply_event(socket, event)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  defp apply_event(socket, {:line, text}) do
    line_no = socket.assigns.line_no + 1
    socket |> assign(line_no: line_no) |> stream_insert(:lines, %{id: line_no, text: text})
  end

  defp apply_event(socket, {:step, step}),
    do: assign(socket, steps: socket.assigns.steps ++ [step])

  defp apply_event(socket, {:restart, outcome}), do: assign(socket, restart: outcome)

  defp apply_event(socket, {:done, result}) do
    Phoenix.PubSub.unsubscribe(Butler.PubSub, Direct.topic(socket.assigns.run_id))
    assign(socket, result: result, run_id: nil)
  end

  defp refuse(socket, {:blocked, jobs}),
    do: assign(socket, refusal: {:blocked, jobs}, run_id: Direct.running())

  defp refuse(socket, :busy),
    do:
      assign(socket,
        error: "Another maintenance run is already in progress.",
        run_id: Direct.running()
      )

  defp refuse(socket, {:guard, reason}),
    do:
      assign(socket,
        error: "The job queue could not be checked (#{inspect(reason)}); nothing was run."
      )

  defp refuse(socket, reason), do: assign(socket, error: "Could not start: #{inspect(reason)}")

  defp cards(order, commands) do
    for key <- order do
      {_atom, label, cli, description} = commands[key]
      {key, label, cli, description}
    end
  end

  defp describe_result({:ok, _}), do: "Command finished successfully."

  defp describe_result({:error, {:exit_status, status}}),
    do: "Command failed (exit status #{status})."

  defp describe_result({:error, {:timeout, _}}), do: "The command timed out and was killed."

  defp describe_result({:error, :stop_timeout}),
    do: "The daemon did not stop in time: the command was not run."

  defp describe_result({:error, :not_stopped}),
    do: "The daemon is still running: the command was not run."

  defp describe_result({:error, {:blocked, _}}),
    do: "A job appeared while stopping the daemon: the command was not run."

  defp describe_result({:error, {:stop_failed, _}}),
    do: "The daemon could not be stopped: the command was not run."

  defp describe_result({:error, reason}), do: "Failed: #{inspect(reason)}"

  defp result_state({:ok, _}), do: :succeeded
  defp result_state({:error, _}), do: :failed

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:maintenance} title="Maintenance">
      <div role="alert" class="alert alert-warning alert-soft">
        <.icon name="hero-exclamation-triangle" class="size-5" />
        <span>
          These commands cannot run while the daemon is up. Butler stops the daemon, runs the command,
          then restarts the daemon. They are refused while jobs are queued or running.
        </span>
      </div>

      <section class="grid gap-4 md:grid-cols-3">
        <div
          :for={{key, label, cli, description} <- cards(@order, @commands)}
          class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm"
        >
          <h2 class="text-lg font-semibold">{label}</h2>
          <p class="mt-1 font-mono text-xs opacity-60">{cli}</p>
          <p class="mt-2 text-sm opacity-80">{description}</p>
          <div class="mt-4 flex gap-2">
            <button
              id={"dry-#{key}"}
              class="btn btn-sm"
              phx-click="ask"
              phx-value-command={key}
              phx-value-mode="dry"
              disabled={@run_id != nil}
            >
              Dry run
            </button>
            <button
              id={"run-#{key}"}
              class="btn btn-sm btn-error"
              phx-click="ask"
              phx-value-command={key}
              phx-value-mode="run"
              disabled={@run_id != nil}
            >
              Run
            </button>
          </div>
        </div>
      </section>

      <div :if={@error} id="direct-error" role="alert" class="alert alert-error alert-soft">
        <.icon name="hero-x-circle" class="size-5" />
        <span>{@error}</span>
      </div>

      <div :if={@refusal} id="direct-refusal" role="alert" class="alert alert-warning alert-soft">
        <.icon name="hero-no-symbol" class="size-5" />
        <div>
          <p class="font-medium">Refused: these jobs are still queued or running.</p>
          <ul class="mt-1 list-inside list-disc text-sm">
            <li :for={job <- elem(@refusal, 1)}>
              <.link navigate={~p"/jobs/#{job.id}"} class="link font-mono">
                {String.slice(job.id, 0, 8)}
              </.link>
              — {job.kind}, {job.state}
            </li>
          </ul>
          <p class="mt-1 text-sm">Wait for them to finish, then try again.</p>
        </div>
      </div>

      <section :if={@run_label || @steps != []} class="space-y-3">
        <div class="flex flex-wrap items-center gap-3">
          <h2 class="text-lg font-semibold">{@run_label}</h2>
          <span :if={@run_id} class="flex items-center gap-2 text-sm opacity-70">
            <span class="loading loading-spinner loading-sm"></span> running
          </span>
        </div>

        <p id="direct-steps" class="text-xs uppercase tracking-wide opacity-60">
          {Enum.join(@steps, " → ")}
        </p>

        <.terminal id="direct-output" title={@run_label}>
          <div id="direct-lines" phx-update="stream">
            <div :for={{dom_id, line} <- @streams.lines} id={dom_id}>{line.text}</div>
          </div>
        </.terminal>

        <div :if={@result} id="direct-result" class="flex flex-wrap items-center gap-3">
          <.status_badge state={result_state(@result)} class="badge-lg" />
          <span class="text-sm">{describe_result(@result)}</span>
        </div>

        <p :if={@restart == :ok} class="text-sm text-success">The daemon was restarted.</p>
        <p :if={match?({:error, _}, @restart)} id="direct-restart-error" class="text-sm text-error">
          The daemon could not be restarted: {inspect(elem(@restart, 1))}. Start it from the Daemon page.
        </p>
      </section>

      <dialog :if={@confirm} id="confirm-dialog" class="modal modal-open" aria-modal="true">
        <div class="modal-box">
          <% {command, dry_run?} = @confirm %>
          <h3 class="text-lg font-semibold">
            {if dry_run?, do: "Dry run", else: "Run"} {elem(@commands[command], 1)}?
          </h3>
          <p class="mt-3 text-sm">
            Butler will <strong>stop the daemon</strong>
            (waiting up to 10 seconds for it to drain), run <code>{elem(@commands[command], 2)}{if dry_run?, do: " --dry-run"}</code>,
            then <strong>restart</strong>
            the daemon, even if the command fails.
          </p>
          <p :if={!dry_run?} class="mt-2 text-sm text-error">
            This can modify your palace and cannot be undone.
          </p>
          <div class="modal-action">
            <button id="confirm-cancel" class="btn" phx-click="cancel">Cancel</button>
            <button id="confirm-ok" class="btn btn-error" phx-click="confirm">Stop daemon and run</button>
          </div>
        </div>
      </dialog>
    </Layouts.app>
    """
  end
end
