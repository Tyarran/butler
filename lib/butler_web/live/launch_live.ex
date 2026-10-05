defmodule ButlerWeb.LaunchLive do
  @moduledoc """
  Launch page: submits jobs to the daemon through the CLI.

  Every submission is validated by `Butler.Commands.Input`, built by
  `Butler.Commands.Args` and sent by `Butler.Commands.Submit`.
  """
  use ButlerWeb, :live_view

  alias Butler.Commands.Args
  alias Butler.Commands.Input
  alias Butler.Commands.Submit

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
     |> assign(page_title: "Launch", result: nil)
     |> assign(mine_form: to_form(@mine_defaults, as: :mine))
     |> assign(modes: Args.modes(), extract_strategies: Args.extract_strategies())}
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
        <% {:ok, job_id} -> %>
          <div role="alert" class="alert alert-success alert-soft">
            <.icon name="hero-check-circle" class="size-5" />
            <span>
              Job submitted:
              <.link navigate={~p"/jobs/#{job_id}"} class="link font-mono">{job_id}</.link>
            </span>
          </div>
        <% {:error, {:duplicate, job_id}} -> %>
          <div role="alert" class="alert alert-warning alert-soft">
            <.icon name="hero-exclamation-triangle" class="size-5" />
            <span>
              An identical job is already queued or running:
              <.link navigate={~p"/jobs/#{job_id}"} class="link font-mono">{job_id}</.link>
            </span>
          </div>
        <% {:error, {:cli, output}} -> %>
          <div role="alert" class="alert alert-error alert-soft">
            <.icon name="hero-x-circle" class="size-5" />
            <span>Submission failed</span>
          </div>
          <.terminal id="submit-output" title="mempalace" text={output} />
        <% {:error, other} -> %>
          <div role="alert" class="alert alert-error alert-soft">
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
    <Layouts.app flash={@flash} active={:launch} title="Launch">
      <p class="text-sm opacity-70">
        Jobs are submitted to the daemon through the <code>mempalace</code>
        CLI and run in the background. If the daemon is stopped, the CLI starts it.
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
            <.icon name="hero-rocket-launch" class="size-4" /> Submit mine job
          </button>
        </.form>
      </section>

      <.submit_result result={@result} />
    </Layouts.app>
    """
  end
end
