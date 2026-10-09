defmodule ButlerWeb.JobsLiveTest do
  use ButlerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Butler.Jobs.Queue
  alias Butler.Test.Engine

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Engine.start_queue!(tmp)
    :ok
  end

  test "shows an empty state when there are no jobs", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert has_element?(view, "#jobs-empty")
    refute has_element?(view, "#jobs tr[id^=job-]")
  end

  test "lists the jobs of the queue with their actions", %{conn: conn} do
    running = Engine.job!("mine", state: :running, payload: %{"source" => "/synthetic/p"})
    queued = Engine.job!("sweep", payload: %{"target" => "/synthetic/t"})
    failed = Engine.job!("mine", state: :failed, error: %{"class" => "CommandFailed"})
    done = Engine.job!("mine", state: :succeeded)

    {:ok, view, _html} = live(conn, ~p"/jobs")

    for job <- [running, queued, failed, done], do: assert(has_element?(view, "#job-#{job.id}"))
    assert has_element?(view, "#cancel-#{running.id}")
    assert has_element?(view, "#cancel-#{queued.id}")
    assert has_element?(view, "#retry-#{failed.id}")
    refute has_element?(view, "#retry-#{done.id}")
    refute has_element?(view, "#cancel-#{done.id}")
  end

  test "a new job appears live, and its state change updates the row", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs")

    job = Engine.job!("sweep", payload: %{"target" => "/synthetic/t"})
    assert has_element?(view, "#job-#{job.id} [data-state=queued]")

    {:ok, _} = Queue.cancel(Queue, job.id)
    assert has_element?(view, "#job-#{job.id} [data-state=cancelled]")
    assert has_element?(view, "#retry-#{job.id}")
  end

  test "cancelling a queued job", %{conn: conn} do
    job = Engine.job!("sweep", payload: %{"target" => "/synthetic/t"})
    {:ok, view, _html} = live(conn, ~p"/jobs")

    # The worker is not running in this test: cancelling a queued job goes
    # through the worker and reports it as unavailable.
    html = view |> element("#cancel-#{job.id}") |> render_click()
    assert html =~ "Could not cancel"
  end

  test "cancelling with a running worker", %{conn: conn} do
    Engine.start_worker!()
    job = Engine.job!("sweep", payload: %{"target" => "/synthetic/t"})
    {:ok, view, _html} = live(conn, ~p"/jobs")

    view |> element("#cancel-#{job.id}") |> render_click()
    assert has_element?(view, "#job-#{job.id} [data-state=cancelled]")
  end

  test "retrying an idempotent kind enqueues a new job at once", %{conn: conn} do
    failed = Engine.job!("sweep", state: :failed, payload: %{"target" => "/synthetic/t"})
    {:ok, view, _html} = live(conn, ~p"/jobs")

    view |> element("#retry-#{failed.id}") |> render_click()
    refute has_element?(view, "#retry-dialog")

    {:ok, jobs} = Queue.list(Queue, state: :queued)
    assert [%{kind: "sweep", payload: %{"target" => "/synthetic/t"}} = new] = jobs
    assert has_element?(view, "#job-#{new.id}")
  end

  test "retrying a non-idempotent kind needs a confirmation", %{conn: conn} do
    failed =
      Engine.job!("diary_write",
        state: :failed,
        payload: %{"agent_name" => "synthetic-agent", "entry" => "synthetic entry"}
      )

    {:ok, view, _html} = live(conn, ~p"/jobs")

    view |> element("#retry-#{failed.id}") |> render_click()
    assert has_element?(view, "#retry-dialog")
    assert {:ok, []} = Queue.list(Queue, state: :queued)

    view |> element("#retry-cancel") |> render_click()
    refute has_element?(view, "#retry-dialog")
    assert {:ok, []} = Queue.list(Queue, state: :queued)

    view |> element("#retry-#{failed.id}") |> render_click()
    view |> element("#retry-confirm") |> render_click()
    assert {:ok, [%{kind: "diary_write"}]} = Queue.list(Queue, state: :queued)
  end

  test "never shows the payload of a diary_write or mcp_tool job", %{conn: conn} do
    Engine.job!("diary_write",
      payload: %{"agent_name" => "synthetic-agent", "entry" => "SECRET-SYNTHETIC-ENTRY"}
    )

    Engine.job!("mcp_tool",
      payload: %{"name" => "mempalace_kg_add", "arguments" => %{"note" => "SECRET-ARG"}}
    )

    {:ok, _view, html} = live(conn, ~p"/jobs")
    refute html =~ "SECRET-SYNTHETIC-ENTRY"
    refute html =~ "SECRET-ARG"
    refute html =~ "mempalace_kg_add"
  end

  describe "filters" do
    setup do
      %{
        mine: Engine.job!("mine", state: :succeeded, payload: %{"source" => "/synthetic/a"}),
        sweep: Engine.job!("sweep", state: :failed),
        queued: Engine.job!("mine", payload: %{"source" => "/synthetic/b"})
      }
    end

    test "without filters, shows every job", %{conn: conn} = jobs do
      {:ok, view, _html} = live(conn, ~p"/jobs")

      for job <- [jobs.mine, jobs.sweep, jobs.queued],
          do: assert(has_element?(view, "#job-#{job.id}"))
    end

    test "filters by state from the query string", %{conn: conn} = jobs do
      {:ok, view, _html} = live(conn, ~p"/jobs?state=failed")
      assert has_element?(view, "#job-#{jobs.sweep.id}")
      refute has_element?(view, "#job-#{jobs.mine.id}")
      refute has_element?(view, "#job-#{jobs.queued.id}")
      assert has_element?(view, "#filter-state-failed.btn-active")
    end

    test "filters by kind and combines both filters", %{conn: conn} = jobs do
      {:ok, view, _html} = live(conn, ~p"/jobs?kind=mine")
      assert has_element?(view, "#job-#{jobs.mine.id}")
      assert has_element?(view, "#job-#{jobs.queued.id}")
      refute has_element?(view, "#job-#{jobs.sweep.id}")

      {:ok, view, _html} = live(conn, ~p"/jobs?kind=mine&state=queued")
      assert has_element?(view, "#job-#{jobs.queued.id}")
      refute has_element?(view, "#job-#{jobs.mine.id}")
    end

    test "ignores unknown states and kinds", %{conn: conn} = jobs do
      {:ok, view, _html} = live(conn, ~p"/jobs?state=bogus&kind=nope")
      assert has_element?(view, "#job-#{jobs.mine.id}")
      assert has_element?(view, "#filter-state-all.btn-active")
      assert has_element?(view, "#filter-kind-all.btn-active")
    end

    test "clicking filters patches the URL and keeps the other filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/jobs")
      view |> element("#filter-state-queued") |> render_click()
      assert_patch(view, ~p"/jobs?state=queued")
      view |> element("#filter-kind-mine") |> render_click()
      assert_patch(view, ~p"/jobs?kind=mine&state=queued")
      view |> element("#filter-state-all") |> render_click()
      assert_patch(view, ~p"/jobs?kind=mine")
    end

    test "live events respect the filters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/jobs?state=queued")
      other = Engine.job!("sweep", state: :succeeded)
      queued = Engine.job!("sweep")

      assert has_element?(view, "#job-#{queued.id}")
      refute has_element?(view, "#job-#{other.id}")

      {:ok, _} = Queue.cancel(Queue, queued.id)
      refute has_element?(view, "#job-#{queued.id}")
    end

    test "lists the kinds present in the queue", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/jobs")
      assert has_element?(view, "#filter-kind-mine")
      assert has_element?(view, "#filter-kind-sweep")
      refute has_element?(view, "#filter-kind-compress")
    end
  end
end
