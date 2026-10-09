defmodule ButlerWeb.JobLiveTest do
  use ButlerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Butler.Jobs.Queue
  alias Butler.Jobs.Worker
  alias Butler.Test.Engine

  @moduletag :tmp_dir

  @tail "\n  MemPalace Mine\n  Wing:    synthetic\n  Files:   2\nDone.\n"

  setup %{tmp_dir: tmp} do
    Engine.start_queue!(tmp)
    :ok
  end

  test "shows a not-found state for an unknown job", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/jobs/does-not-exist")

    assert html =~ "Job not found"
    assert has_element?(view, "#job-not-found")
    assert has_element?(view, ~s(a[href="/jobs"]))
  end

  test "shows the job summary, attempts, priority and dedupe key", %{conn: conn} do
    job =
      Engine.job!("mine",
        state: :succeeded,
        priority: 2,
        dedupe_key: "dedupe-xyz",
        payload: %{"source" => "/synthetic/project"}
      )

    {:ok, view, html} = live(conn, ~p"/jobs/#{job.id}")

    assert html =~ job.id
    assert has_element?(view, "#job-state [data-state=succeeded]")
    assert has_element?(view, "#job-attempts", "1")
    assert has_element?(view, "#job-priority", "2")
    assert has_element?(view, "#job-dedupe", "dedupe-xyz")
    assert has_element?(view, "#job-payload", "/synthetic/project")
  end

  test "shows the output tail of a finished job from its result", %{conn: conn} do
    job = Engine.job!("mine", state: :succeeded, result: %{exit_status: 0, output_tail: @tail})
    {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")

    assert has_element?(view, "#job-tail", "MemPalace Mine")
    refute has_element?(view, "#job-live-output")
    assert has_element?(view, "#job-result", "exit_status")
    refute has_element?(view, "#job-result", "MemPalace Mine")
  end

  test "shows a failed job's error and its output tail", %{conn: conn} do
    job =
      Engine.job!("mine",
        state: :failed,
        error: %{class: "CommandFailed", message: "exit 2", output_tail: "boom synthetic\n"}
      )

    {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")
    assert has_element?(view, "#job-error", "CommandFailed")
    assert has_element?(view, "#job-tail", "boom synthetic")
    assert has_element?(view, "#retry-job")
  end

  test "escapes HTML found in outputs", %{conn: conn} do
    job =
      Engine.job!("mine", state: :succeeded, result: %{output_tail: "<script>alert(1)</script>"})

    {:ok, _view, html} = live(conn, ~p"/jobs/#{job.id}")
    refute html =~ "<script>alert(1)</script>"
    assert html =~ "&lt;script&gt;"
  end

  test "does not show sections that have no data", %{conn: conn} do
    job = Engine.job!("sweep", payload: %{"target" => "/synthetic"})
    {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")

    refute has_element?(view, "#job-error")
    refute has_element?(view, "#job-tail")
    refute has_element?(view, "#job-result")
  end

  test "streams the live output of a running job", %{conn: conn} do
    job = Engine.job!("mine", state: :running, payload: %{"source" => "/synthetic/p"})
    {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")
    assert has_element?(view, "#job-live-output")

    Phoenix.PubSub.broadcast(
      Butler.PubSub,
      Worker.job_topic(job.id),
      {:job_output, job.id, "  + [1/2] a.md"}
    )

    assert has_element?(view, "#job-live-lines", "[1/2] a.md")
    assert has_element?(view, "#cancel-job")
  end

  test "follows the job to its end", %{conn: conn} do
    job = Engine.job!("mine", state: :running, payload: %{"source" => "/synthetic/p"})
    {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")
    assert has_element?(view, "#job-state [data-state=running]")

    {:ok, _} = Queue.finish(Queue, job.id, :succeeded, %{result: %{output_tail: @tail}})

    assert has_element?(view, "#job-state [data-state=succeeded]")
    assert has_element?(view, "#job-tail", "MemPalace Mine")
    refute has_element?(view, "#job-live-output")
    refute has_element?(view, "#cancel-job")
  end

  test "shows the queue position of a queued job", %{conn: conn} do
    first = Engine.job!("sweep", payload: %{"target" => "/synthetic/a"})
    second = Engine.job!("sweep", payload: %{"target" => "/synthetic/b"})

    {:ok, view, _html} = live(conn, ~p"/jobs/#{second.id}")
    assert has_element?(view, "#job-position", "#2")

    {:ok, _} = Queue.cancel(Queue, first.id)
    assert has_element?(view, "#job-position", "#1")
  end

  test "hides the payload of diary_write and mcp_tool jobs", %{conn: conn} do
    diary =
      Engine.job!("diary_write",
        payload: %{"agent_name" => "synthetic-agent", "entry" => "SECRET-SYNTHETIC-ENTRY"}
      )

    tool =
      Engine.job!("mcp_tool",
        payload: %{"name" => "mempalace_kg_add", "arguments" => %{"note" => "SECRET-ARG"}}
      )

    for job <- [diary, tool] do
      {:ok, view, html} = live(conn, ~p"/jobs/#{job.id}")
      assert has_element?(view, "#job-payload-hidden")
      refute has_element?(view, "#job-payload")
      refute html =~ "SECRET"
    end
  end

  test "retry enqueues a new job and navigates to it", %{conn: conn} do
    job = Engine.job!("sweep", state: :failed, payload: %{"target" => "/synthetic/t"})
    {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")

    view |> element("#retry-job") |> render_click()
    {path, _flash} = assert_redirect(view)

    assert {:ok, [%{id: new_id}]} = Queue.list(Queue, state: :queued)
    assert path == "/jobs/#{new_id}"
  end

  test "retry of a non-idempotent kind asks for a confirmation", %{conn: conn} do
    job =
      Engine.job!("repair", state: :failed, payload: %{})

    {:ok, view, _html} = live(conn, ~p"/jobs/#{job.id}")

    view |> element("#retry-job") |> render_click()
    assert has_element?(view, "#retry-dialog")
    assert {:ok, []} = Queue.list(Queue, state: :queued)

    view |> element("#retry-confirm") |> render_click()
    assert_redirect(view)
    assert {:ok, [%{kind: "repair"}]} = Queue.list(Queue, state: :queued)
  end
end
