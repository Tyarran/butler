defmodule ButlerWeb.UIComponents do
  @moduledoc """
  Small reusable dashboard components: status badge, stat card and terminal block.
  """
  use Phoenix.Component

  import ButlerWeb.CoreComponents, only: [icon: 1]

  @badge_classes %{
    queued: "badge-info",
    running: "badge-warning",
    succeeded: "badge-success",
    failed: "badge-error",
    cancelled: "badge-neutral",
    stopped: "badge-neutral"
  }

  @doc """
  A colored badge for a job state (`:queued`, `:running`, `:succeeded`,
  `:failed`, `:cancelled`) or a daemon state (`:running`, `:stopped`).

  With `kind={:daemon}` a running state is green instead of amber.
  """
  attr :state, :atom, required: true
  attr :kind, :atom, default: :job, values: [:job, :daemon]
  attr :class, :string, default: nil

  def status_badge(assigns) do
    assigns = assign(assigns, :color, badge_color(assigns.state, assigns.kind))

    ~H"""
    <span class={["badge badge-soft gap-1.5", @color, @class]} data-state={@state}>
      <span :if={@state == :running and @kind == :job} class="status status-warning animate-pulse"></span>
      {@state}
    </span>
    """
  end

  defp badge_color(:running, :daemon), do: "badge-success"
  defp badge_color(state, _kind), do: Map.get(@badge_classes, state, "badge-ghost")

  @doc """
  A statistic card: a title, a large value and an optional hint and icon.
  """
  attr :title, :string, required: true
  attr :value, :any, default: nil
  attr :hint, :string, default: nil
  attr :icon, :string, default: nil
  attr :tone, :atom, default: :default, values: [:default, :info, :warning, :success, :error]
  attr :rest, :global

  def stat_card(assigns) do
    ~H"""
    <div class="rounded-box border border-base-300 bg-base-100 p-4 shadow-sm" {@rest}>
      <div class="flex items-center justify-between text-sm opacity-70">
        <span>{@title}</span>
        <.icon :if={@icon} name={@icon} class="size-5" />
      </div>
      <div class={["mt-2 text-3xl font-semibold tabular-nums", tone_class(@tone)]}>
        {if is_nil(@value), do: "—", else: @value}
      </div>
      <div :if={@hint} class="mt-1 text-xs opacity-60">{@hint}</div>
    </div>
    """
  end

  # Full class names so that Tailwind can detect them.
  defp tone_class(:default), do: nil
  defp tone_class(:info), do: "text-info"
  defp tone_class(:warning), do: "text-warning"
  defp tone_class(:success), do: "text-success"
  defp tone_class(:error), do: "text-error"

  @doc """
  A terminal-style block for long outputs (command stdout, job results).

  The text is rendered verbatim, HTML-escaped, in a scrollable monospaced
  block.
  """
  attr :id, :string, required: true
  attr :title, :string, default: nil
  attr :text, :string, default: nil
  attr :class, :string, default: nil
  slot :inner_block, doc: "rendered instead of `text` when given (e.g. a stream)"

  def terminal(assigns) do
    ~H"""
    <div class={[
      "rounded-box overflow-hidden border border-base-300 bg-neutral text-neutral-content",
      @class
    ]}>
      <div class="flex items-center gap-2 border-b border-white/10 px-3 py-2 text-xs">
        <span class="size-2.5 rounded-full bg-error"></span>
        <span class="size-2.5 rounded-full bg-warning"></span>
        <span class="size-2.5 rounded-full bg-success"></span>
        <span :if={@title} class="ml-2 opacity-70">{@title}</span>
      </div>
      <pre
        id={@id}
        phx-no-format
        class="max-h-[32rem] overflow-auto whitespace-pre-wrap break-words p-4 font-mono text-xs leading-relaxed"
      ><span :if={@inner_block != []}>{render_slot(@inner_block)}</span><span :if={@inner_block == [] and @text in [nil, ""]} class="opacity-50">No output</span><span :if={@inner_block == [] and @text not in [nil, ""]}>{@text}</span></pre>
    </div>
    """
  end
end
