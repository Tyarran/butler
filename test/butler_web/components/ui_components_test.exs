defmodule ButlerWeb.UIComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias ButlerWeb.UIComponents

  describe "status_badge/1" do
    test "maps each state to a distinct style and label" do
      expectations = [
        queued: {"badge-info", "queued"},
        running: {"badge-warning", "running"},
        succeeded: {"badge-success", "succeeded"},
        failed: {"badge-error", "failed"},
        cancelled: {"badge-neutral", "cancelled"},
        stopped: {"badge-neutral", "stopped"},
        unknown: {"badge-ghost", "unknown"}
      ]

      for {state, {class, label}} <- expectations do
        html = render_component(&UIComponents.status_badge/1, state: state)
        assert html =~ class, "#{state} should use #{class}"
        assert html =~ label
      end
    end

    test "the daemon running state is green, unlike a running job" do
      html = render_component(&UIComponents.status_badge/1, state: :running, kind: :daemon)
      assert html =~ "badge-success"
    end
  end

  describe "stat_card/1" do
    test "renders title, value and hint" do
      html =
        render_component(&UIComponents.stat_card/1,
          title: "Failed",
          value: 5,
          hint: "last 7 days",
          tone: :error
        )

      assert html =~ "Failed"
      assert html =~ ~r/>\s*5\s*</
      assert html =~ "last 7 days"
      assert html =~ "text-error"
    end

    test "renders a placeholder when the value is nil" do
      html = render_component(&UIComponents.stat_card/1, title: "Queued", value: nil)
      assert html =~ "—"
    end
  end

  describe "terminal/1" do
    test "renders text verbatim in a monospaced block, HTML-escaped" do
      html =
        render_component(&UIComponents.terminal/1,
          id: "out",
          title: "stdout",
          text: "line 1\n<script>alert(1)</script>\n"
        )

      assert html =~ ~s(id="out")
      assert html =~ "stdout"
      assert html =~ "font-mono"
      assert html =~ "line 1"
      assert html =~ "&lt;script&gt;"
      refute html =~ "<script>alert"
    end

    test "renders an empty state" do
      html = render_component(&UIComponents.terminal/1, id: "out", text: nil)
      assert html =~ "No output"
    end
  end
end
