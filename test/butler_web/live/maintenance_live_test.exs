defmodule ButlerWeb.MaintenanceLiveTest do
  use ButlerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Butler.Jobs.Queue
  alias Butler.Test.Engine

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Engine.start_queue!(tmp)
    :ok
  end

  defp queued, do: elem(Queue.list(Queue, state: :queued), 1)

  test "offers the three maintenance commands", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/maintenance")

    for kind <- ~w(repair compress migrate-wings) do
      assert has_element?(view, "#dry-#{kind}")
      assert has_element?(view, "#run-#{kind}")
    end

    assert has_element?(view, "#maintenance-empty")
  end

  test "asks for a confirmation and queues nothing before it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/maintenance")

    view |> element("#run-repair") |> render_click()
    assert has_element?(view, "#confirm-dialog")
    assert queued() == []

    view |> element("#confirm-cancel") |> render_click()
    refute has_element?(view, "#confirm-dialog")
    assert queued() == []
  end

  test "a confirmed run is queued, not executed", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/maintenance")

    view |> element("#run-repair") |> render_click()
    view |> element("#confirm-ok") |> render_click()

    refute has_element?(view, "#confirm-dialog")
    assert has_element?(view, "#maintenance-queued")
    assert [%{kind: "repair", payload: %{"dry_run" => false}} = job] = queued()
    assert has_element?(view, "#maintenance-job-#{job.id} [data-state=queued]")
  end

  test "a dry run is queued as a dry run", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/maintenance")

    view |> element("#dry-migrate-wings") |> render_click()
    view |> element("#confirm-ok") |> render_click()

    assert [%{kind: "migrate-wings", payload: %{"dry_run" => true}}] = queued()
  end

  test "an identical queued job is reported", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/maintenance")

    for _ <- 1..2 do
      view |> element("#run-compress") |> render_click()
      view |> element("#confirm-ok") |> render_click()
    end

    assert has_element?(view, "#maintenance-duplicate")
    assert [_one] = queued()
  end

  test "shows the queue position behind other jobs", %{conn: conn} do
    Engine.job!("sweep", payload: %{"target" => "/synthetic/t"})
    {:ok, view, _html} = live(conn, ~p"/maintenance")

    view |> element("#run-repair") |> render_click()
    view |> element("#confirm-ok") |> render_click()

    assert has_element?(view, "#maintenance-queued-position", "#2")
  end

  test "follows the jobs live", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/maintenance")
    job = Engine.job!("repair", payload: %{})
    assert has_element?(view, "#maintenance-job-#{job.id}")

    {:ok, _} = Queue.cancel(Queue, job.id)
    refute has_element?(view, "#maintenance-job-#{job.id}")
    assert has_element?(view, "#maintenance-empty")
  end

  test "ignores unknown commands", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/maintenance")
    render_click(view, "ask", %{"command" => "rm-rf", "mode" => "run"})
    refute has_element?(view, "#confirm-dialog")
  end
end
