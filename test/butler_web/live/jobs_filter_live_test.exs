defmodule ButlerWeb.JobsFilterLiveTest do
  use ButlerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Butler.Jobs.Watcher
  alias Butler.Test.DaemonFixture
  alias Butler.Test.QueueFixture

  setup do
    fixture = DaemonFixture.install!(running: true)

    QueueFixture.insert_job!(fixture.queue, id: "mine-ok", kind: "mine", state: "succeeded")
    QueueFixture.insert_job!(fixture.queue, id: "mine-bad", kind: "mine", state: "failed")
    QueueFixture.insert_job!(fixture.queue, id: "tool-bad", kind: "mcp_tool", state: "failed")
    QueueFixture.insert_job!(fixture.queue, id: "tool-run", kind: "mcp_tool", state: "running")

    {:ok, fixture: fixture}
  end

  test "without filters, shows every job", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs")

    for id <- ~w(mine-ok mine-bad tool-bad tool-run) do
      assert has_element?(view, "#job-#{id}")
    end
  end

  test "filters by state from the query string", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs?state=failed")

    assert has_element?(view, "#job-mine-bad")
    assert has_element?(view, "#job-tool-bad")
    refute has_element?(view, "#job-mine-ok")
    refute has_element?(view, "#job-tool-run")
  end

  test "filters by kind from the query string", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs?kind=mcp_tool")

    assert has_element?(view, "#job-tool-bad")
    assert has_element?(view, "#job-tool-run")
    refute has_element?(view, "#job-mine-ok")
  end

  test "combines both filters", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs?kind=mine&state=failed")

    assert has_element?(view, "#job-mine-bad")
    refute has_element?(view, "#job-tool-bad")
    refute has_element?(view, "#job-mine-ok")
  end

  test "filters the active section too", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs?state=failed")
    refute has_element?(view, "#active-jobs #job-tool-run")
  end

  test "ignores unknown states and kinds", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs?state=bogus&kind=%27%20OR%201=1")

    for id <- ~w(mine-ok mine-bad tool-bad tool-run) do
      assert has_element?(view, "#job-#{id}")
    end
  end

  test "clicking a state filter patches the URL", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs")

    view |> element("#filter-state-failed") |> render_click()

    assert_patch(view, ~p"/jobs?state=failed")
    refute has_element?(view, "#job-mine-ok")
  end

  test "clicking a kind filter keeps the state filter", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs?state=failed")

    view |> element("#filter-kind-mine") |> render_click()

    assert_patch(view, ~p"/jobs?kind=mine&state=failed")
    assert has_element?(view, "#job-mine-bad")
    refute has_element?(view, "#job-tool-bad")
  end

  test "the All links clear a filter", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs?kind=mine&state=failed")

    view |> element("#filter-state-all") |> render_click()
    assert_patch(view, ~p"/jobs?kind=mine")

    view |> element("#filter-kind-all") |> render_click()
    assert_patch(view, ~p"/jobs")
  end

  test "marks the selected filters", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs?state=failed")

    assert has_element?(view, "#filter-state-failed.btn-active")
    assert has_element?(view, "#filter-kind-all.btn-active")
  end

  test "lists the kinds present in the queue", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert has_element?(view, "#filter-kind-mine")
    assert has_element?(view, "#filter-kind-mcp_tool")
  end

  test "keeps the filters when the queue changes", %{conn: conn, fixture: fixture} do
    {:ok, view, _html} = live(conn, ~p"/jobs?state=failed")

    QueueFixture.insert_job!(fixture.queue, id: "late-bad", state: "failed")
    QueueFixture.insert_job!(fixture.queue, id: "late-ok", state: "succeeded")
    Phoenix.PubSub.broadcast(Butler.PubSub, Watcher.topic(), {:queue_changed, :x})

    assert render(view) =~ "late-bad"
    refute has_element?(view, "#job-late-ok")
  end
end
