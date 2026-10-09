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

  test "a second confirm after the reset queues nothing more", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/maintenance")

    view |> element("#run-repair") |> render_click()
    view |> element("#confirm-ok") |> render_click()
    assert [_one] = queued()

    # A double click: the confirmation is already gone.
    render_click(view, "confirm", %{})

    assert [_one] = queued()
    assert has_element?(view, "#maintenance-queued")
    refute has_element?(view, "#confirm-dialog")
  end

  test "many jobs of other kinds do not hide a maintenance job", %{conn: conn} do
    repair = Engine.job!("repair", payload: %{})
    for _ <- 1..501, do: Engine.job!("sweep", payload: %{"target" => "/synthetic/t"})

    {:ok, view, _html} = live(conn, ~p"/maintenance")

    assert has_element?(view, "#maintenance-job-#{repair.id}")
  end

  test "every page shows the maintenance banner while a job runs, and drops it after",
       %{conn: conn} do
    on_exit(&Butler.Maintenance.leave/0)

    views =
      for path <- ["/jobs", "/launch", "/maintenance", "/mcp", "/palace", "/worker"] do
        {:ok, view, _html} = live(conn, path)
        refute has_element?(view, "#maintenance-banner")
        view
      end

    :ok = Butler.Maintenance.enter("job-1234")
    for view <- views, do: assert(has_element?(view, "#maintenance-banner"))

    :ok = Butler.Maintenance.leave()
    for view <- views, do: refute(has_element?(view, "#maintenance-banner"))
  end

  test "ignores unknown commands", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/maintenance")
    render_click(view, "ask", %{"command" => "rm-rf", "mode" => "run"})
    refute has_element?(view, "#confirm-dialog")
  end
end
