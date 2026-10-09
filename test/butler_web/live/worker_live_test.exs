defmodule ButlerWeb.WorkerLiveTest do
  use ButlerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Butler.Jobs
  alias Butler.Maintenance
  alias Butler.Test.Engine

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Engine.start_queue!(tmp)
    on_exit(&Maintenance.leave/0)
    :ok
  end

  test "shows the engine as unavailable when the worker is not running", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/worker")

    assert has_element?(view, "#worker-status [data-state=unavailable]")
    assert has_element?(view, "#worker-counts #count-queued")
    assert has_element?(view, "#worker-active-job", "none")
  end

  test "explains that the worker is blocked by the legacy daemon", %{conn: conn} do
    Engine.start_worker!()
    {:ok, view, _html} = live(conn, ~p"/worker")

    assert has_element?(view, "#worker-status [data-state=blocked]")
    assert has_element?(view, "#worker-status-text", "Python daemon")
  end

  test "shows an idle worker", %{conn: conn} do
    Engine.start_worker!(legacy_running?: fn -> false end)
    {:ok, view, _html} = live(conn, ~p"/worker")
    assert has_element?(view, "#worker-status [data-state=idle]")
  end

  test "counters follow the queue", %{conn: conn} do
    Engine.start_worker!()
    {:ok, view, _html} = live(conn, ~p"/worker")
    assert has_element?(view, "#count-queued", "0")

    {:ok, _job, :created} = Jobs.enqueue("sweep", %{"target" => "/synthetic/transcripts"})
    assert has_element?(view, "#count-queued", "1")
  end

  test "the maintenance banner follows the maintenance flag", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/worker")
    refute has_element?(view, "#maintenance-banner")

    :ok = Maintenance.enter("job-1234")
    assert has_element?(view, "#maintenance-banner")
    assert has_element?(view, "#maintenance-banner-job")
    assert has_element?(view, "#worker-maintenance", "active")

    :ok = Maintenance.leave()
    refute has_element?(view, "#maintenance-banner")
  end

  test "the banner shows on every page", %{conn: conn} do
    :ok = Maintenance.enter(nil)
    {:ok, view, _html} = live(conn, ~p"/palace")
    assert has_element?(view, "#maintenance-banner")
    refute has_element?(view, "#maintenance-banner-job")
  end
end
