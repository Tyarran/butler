defmodule ButlerWeb.LaunchLive do
  @moduledoc """
  Launch page: queues `mine`, `sweep` and `sync` jobs in Butler's own queue.

  Every submission is validated by `Butler.Commands.Input`, then queued by
  `Butler.Commands.Submit` (which validates it again with the rules of the
  worker). Nothing runs here: the serial worker picks the job up. A sync is a
  dry run unless the user applies it after an explicit confirmation.
  """
  use ButlerWeb, :live_view

  alias Butler.Commands.Input
  alias Butler.Commands.Submit
  alias Butler.Jobs.Kinds

  @mine_defaults %{
    "dir" => "",
    "mode" => "",
    "wing" => "",
    "agent" => "",
    "dry_run" => "false",
    "limit" => "",
    "no_gitignore" => "false",
    "include_ignored" => "",
    "extract" => "",
    "max_chunks_per_file" => "",
    "redetect_origin" => "false"
  }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(page_title: "Launch", result: nil, confirm_sync: nil)
     |> assign(mine_form: to_form(@mine_defaults, as: :mine))
     |> assign(sweep_form: to_form(%{"target" => ""}, as: :sweep))
     |> assign(sync_form: to_form(%{"wing" => "", "roots" => ""}, as: :sync))
     |> assign(modes: Kinds.modes(), extract_strategies: Kinds.extract_strategies())}
  end

  @impl Phoenix.LiveView
  def handle_event("submit_mine", %{"mine" => params}, socket) do
    case Input.mine(params) do
      {:ok, input} ->
        {:noreply,
         assign(socket, mine_form: to_form(params, as: :mine), result: Submit.mine(input))}

      {:error, errors} ->
        {:noreply, assign(socket, mine_form: error_form(params, :mine, errors), result: nil)}
    end
  end

  def handle_event("submit_sweep", %{"sweep" => params}, socket) do
    case Input.sweep(params) do
      {:ok, input} ->
        {:noreply,
         assign(socket, sweep_form: to_form(params, as: :sweep), result: Submit.sweep(input))}

      {:error, errors} ->
        {:noreply, assign(socket, sweep_form: error_form(params, :sweep, errors), result: nil)}
    end
  end

  def handle_event("submit_sync", %{"sync" => params} = all, socket) do
    apply? = all["intent"] == "apply"

    case Input.sync(params) do
      {:ok, input} when apply? ->
        ask_apply(socket, params, input)

      {:ok, input} ->
        {:noreply,
         assign(socket, sync_form: to_form(params, as: :sync), result: Submit.sync(input))}

      {:error, errors} ->
        {:noreply, assign(socket, sync_form: error_form(params, :sync, errors), result: nil)}
    end
  end

  def handle_event("confirm_sync", _params, %{assigns: %{confirm_sync: input}} = socket)
      when is_map(input) do
    {:noreply, assign(socket, confirm_sync: nil, result: Submit.sync(input, apply: true))}
  end

  def handle_event("cancel_sync", _params, socket),
    do: {:noreply, assign(socket, confirm_sync: nil)}

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  # Applying a sync deletes drawers: it needs a scope and a confirmation.
  defp ask_apply(socket, params, %{wing: nil, roots: []}) do
    errors = %{wing: "applying needs a wing or at least one root"}
    {:noreply, assign(socket, sync_form: error_form(params, :sync, errors), result: nil)}
  end

  defp ask_apply(socket, params, input) do
    {:noreply,
     assign(socket, sync_form: to_form(params, as: :sync), confirm_sync: input, result: nil)}
  end

  defp error_form(params, as, errors) do
    to_form(params,
      as: as,
      errors: Enum.map(errors, fn {field, message} -> {field, {message, []}} end)
    )
  end

  attr :result, :any, default: nil

  defp submit_result(assigns) do
    ~H"""
    <div :if={@result} id="submit-result" class="space-y-3">
      <%= case @result do %>
        <% {:ok, job} -> %>
          <div id="submit-ok" role="alert" class="alert alert-success alert-soft">
            <.icon name="hero-check-circle" class="size-5" />
            <span>
              Job queued:
              <.link navigate={~p"/jobs/#{job.id}"} class="link font-mono">{job.id}</.link>
            </span>
          </div>
        <% {:error, {:duplicate, job}} -> %>
          <div id="submit-duplicate" role="alert" class="alert alert-warning alert-soft">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>
              An identical job is already queued or running:
              <.link navigate={~p"/jobs/#{job.id}"} class="link font-mono">{job.id}</.link>
            </span>
          </div>
        <% {:error, {:unavailable, _reason}} -> %>
          <div id="submit-unavailable" role="alert" class="alert alert-error alert-soft">
            <.icon name="hero-x-circle" class="size-5" />
            <span>The job queue is not available: nothing was queued.</span>
          </div>
        <% {:error, other} -> %>
          <div id="submit-refused" role="alert" class="alert alert-error alert-soft">
            <.icon name="hero-x-circle" class="size-5" />
            <span>Submission refused: {inspect(other)}</span>
          </div>
      <% end %>
    </div>
    """
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:launch} title="Launch" maintenance={@maintenance}>
      <p class="text-sm opacity-70">
        Jobs are queued in Butler and run one at a time by the worker
        (<.link navigate={~p"/worker"} class="link">status</.link>).
      </p>

      <section class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm">
        <h2 class="text-lg font-semibold">Mine</h2>
        <p class="mb-4 text-sm opacity-70">Index a directory into the palace.</p>

        <.form for={@mine_form} id="mine-form" phx-submit="submit_mine">
          <div class="grid gap-x-4 md:grid-cols-2">
            <.input
              field={@mine_form[:dir]}
              label="Directory"
              placeholder="/absolute/path"
              class="w-full input"
            />
            <.input
              field={@mine_form[:mode]}
              type="select"
              label="Mode"
              prompt="Default (projects)"
              options={@modes}
            />
            <.input
              field={@mine_form[:wing]}
              label="Wing"
              placeholder="Default: directory name"
              class="w-full input"
            />
            <.input
              field={@mine_form[:agent]}
              label="Agent"
              placeholder="Default: mempalace"
              class="w-full input"
            />
            <.input
              field={@mine_form[:limit]}
              label="Max files"
              type="number"
              min="1"
              class="w-full input"
            />
            <.input
              field={@mine_form[:max_chunks_per_file]}
              label="Max chunks per file"
              type="number"
              min="1"
              class="w-full input"
            />
            <.input
              field={@mine_form[:extract]}
              type="select"
              label="Extraction (convos mode)"
              prompt="Default (exchange)"
              options={@extract_strategies}
            />
            <.input
              field={@mine_form[:include_ignored]}
              label="Always include (ignored paths, comma separated)"
              class="w-full input"
            />
          </div>
          <div class="mt-2 flex flex-wrap gap-x-6">
            <.input field={@mine_form[:dry_run]} type="checkbox" label="Dry run (preview only)" />
            <.input field={@mine_form[:no_gitignore]} type="checkbox" label="Ignore .gitignore files" />
            <.input field={@mine_form[:redetect_origin]} type="checkbox" label="Re-detect origin" />
          </div>
          <button type="submit" class="btn btn-primary mt-4" phx-disable-with="Submitting…">
            <.icon name="hero-rocket-launch" class="size-4" /> Queue mine job
          </button>
        </.form>
      </section>

      <section class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm">
        <h2 class="text-lg font-semibold">Sweep</h2>
        <p class="mb-4 text-sm opacity-70">
          Sweep a <code>.jsonl</code> transcript file, or a directory scanned recursively.
        </p>

        <.form for={@sweep_form} id="sweep-form" phx-submit="submit_sweep">
          <.input
            field={@sweep_form[:target]}
            label="Target (file or directory)"
            placeholder="/absolute/path"
            class="w-full input"
          />
          <button type="submit" class="btn btn-primary mt-2" phx-disable-with="Submitting…">
            <.icon name="hero-rocket-launch" class="size-4" /> Queue sweep job
          </button>
        </.form>
      </section>

      <section class="rounded-box border border-base-300 bg-base-100 p-5 shadow-sm">
        <div class="flex items-center gap-2">
          <h2 class="text-lg font-semibold">Sync</h2>
          <span id="sync-default-dry-run" class="badge badge-info badge-soft">Dry run by default</span>
        </div>
        <p class="mb-4 text-sm opacity-70">
          Preview which drawers a sync would delete, or apply it (needs a wing or roots, and a confirmation).
        </p>

        <.form for={@sync_form} id="sync-form" phx-submit="submit_sync">
          <.input field={@sync_form[:wing]} label="Wing (optional)" class="w-full input" />
          <.input
            field={@sync_form[:roots]}
            type="textarea"
            label="Additional project roots (one per line, optional)"
            rows="3"
          />
          <div class="mt-2 flex flex-wrap gap-2">
            <button
              id="sync-dry-run"
              type="submit"
              name="intent"
              value="dry_run"
              class="btn btn-primary"
              phx-disable-with="Submitting…"
            >
              <.icon name="hero-rocket-launch" class="size-4" /> Queue sync dry run
            </button>
            <button
              id="sync-apply"
              type="submit"
              name="intent"
              value="apply"
              class="btn btn-error btn-soft"
            >
              <.icon name="hero-exclamation-triangle" class="size-4" /> Apply sync…
            </button>
          </div>
        </.form>
      </section>

      <.submit_result result={@result} />

      <dialog :if={@confirm_sync} id="sync-confirm-dialog" class="modal modal-open" aria-modal="true">
        <div class="modal-box">
          <h3 class="text-lg font-semibold">Apply sync?</h3>
          <p class="mt-3 text-sm">
            <code>mempalace sync --apply</code>
            deletes from the palace the drawers whose source files are gone.
          </p>
          <p class="mt-2 text-sm text-error">This modifies your palace and cannot be undone.</p>
          <div class="modal-action">
            <button id="sync-confirm-cancel" class="btn" phx-click="cancel_sync">Cancel</button>
            <button id="sync-confirm-ok" class="btn btn-error" phx-click="confirm_sync">
              Queue sync --apply
            </button>
          </div>
        </div>
      </dialog>
    </Layouts.app>
    """
  end
end
