defmodule ButlerWeb.LaunchLiveTest do
  use ButlerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Butler.Jobs.Queue
  alias Butler.Test.Engine

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Engine.start_queue!(tmp)
    dir = Path.join(tmp, "project")
    File.mkdir_p!(dir)
    {:ok, dir: dir}
  end

  defp queued, do: elem(Queue.list(Queue, state: :queued), 1)

  test "queues a mine job", %{conn: conn, dir: dir} do
    {:ok, view, _html} = live(conn, ~p"/launch")

    view |> form("#mine-form", mine: %{dir: dir, dry_run: "true"}) |> render_submit()

    assert has_element?(view, "#submit-ok")
    assert [%{kind: "mine", payload: %{"source" => ^dir, "dry_run" => true}}] = queued()
  end

  test "shows field errors and queues nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/launch")
    view |> form("#mine-form", mine: %{dir: "relative"}) |> render_submit()

    refute has_element?(view, "#submit-ok")
    assert queued() == []
  end

  test "a second identical submission is reported as a duplicate", %{conn: conn, dir: dir} do
    {:ok, view, _html} = live(conn, ~p"/launch")
    view |> form("#sweep-form", sweep: %{target: dir}) |> render_submit()
    assert has_element?(view, "#submit-ok")

    view |> form("#sweep-form", sweep: %{target: dir}) |> render_submit()
    assert has_element?(view, "#submit-duplicate")
    assert [_one] = queued()
  end

  test "sync queues a dry run", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/launch")
    view |> form("#sync-form", sync: %{wing: "synthetic"}) |> render_submit(%{intent: "dry_run"})

    assert [%{kind: "sync", payload: %{"dry_run" => true}}] = queued()
  end

  test "sync apply needs a scope", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/launch")
    view |> form("#sync-form", sync: %{wing: ""}) |> render_submit(%{intent: "apply"})

    refute has_element?(view, "#sync-confirm-dialog")
    assert queued() == []
  end

  test "sync apply is queued only after a confirmation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/launch")
    view |> form("#sync-form", sync: %{wing: "synthetic"}) |> render_submit(%{intent: "apply"})

    assert has_element?(view, "#sync-confirm-dialog")
    assert queued() == []

    view |> element("#sync-confirm-cancel") |> render_click()
    refute has_element?(view, "#sync-confirm-dialog")
    assert queued() == []

    view |> form("#sync-form", sync: %{wing: "synthetic"}) |> render_submit(%{intent: "apply"})
    view |> element("#sync-confirm-ok") |> render_click()

    assert [%{kind: "sync", payload: %{"dry_run" => false, "wing" => "synthetic"}}] = queued()
    assert has_element?(view, "#submit-ok")
  end

  test "reports an unavailable queue", %{conn: conn, dir: dir} do
    {:ok, view, _html} = live(conn, ~p"/launch")
    stop_supervised!(Queue)
    view |> form("#sweep-form", sweep: %{target: dir}) |> render_submit()
    assert has_element?(view, "#submit-unavailable")
  end
end
