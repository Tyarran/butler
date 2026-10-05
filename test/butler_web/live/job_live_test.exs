defmodule ButlerWeb.JobLiveTest do
  use ButlerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Butler.Jobs.Watcher
  alias Butler.Test.DaemonFixture
  alias Butler.Test.QueueFixture

  @stdout "\n  MemPalace Mine\n  Wing:    synthetic\n  Files:   2\n  + [1/2] a.md\nDone.\n"

  setup do
    {:ok, fixture: DaemonFixture.install!(running: true)}
  end

  test "shows a not-found state for an unknown job", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/jobs/does-not-exist")

    assert html =~ "Job not found"
    assert has_element?(view, ~s(a[href="/jobs"]))
  end

  test "shows a not-found state without any queue database", %{conn: conn} do
    DaemonFixture.install!(queue: false)
    {:ok, _view, html} = live(conn, ~p"/jobs/abc")
    assert html =~ "Job not found"
  end

  test "shows the job summary, timings, attempts and dedupe key", %{conn: conn, fixture: f} do
    QueueFixture.insert_job!(f.queue,
      id: "job-detail-1",
      kind: "mine",
      state: "succeeded",
      priority: 2,
      attempts: 1,
      dedupe_key: "dedupe-xyz",
      created_at: "2026-01-01T10:00:00.123456+00:00",
      started_at: "2026-01-01T10:00:05+00:00",
      finished_at: "2026-01-01T10:05:35+00:00"
    )

    {:ok, view, html} = live(conn, ~p"/jobs/job-detail-1")

    assert html =~ "job-detail-1"
    assert has_element?(view, "#job-state [data-state=succeeded]")
    assert html =~ "2026-01-01 10:00:00 UTC"
    assert html =~ "2026-01-01 10:00:05 UTC"
    assert html =~ "2026-01-01 10:05:35 UTC"
    assert view |> element("#job-duration") |> render() =~ "5m 30s"
    assert view |> element("#job-attempts") |> render() =~ "1"
    assert view |> element("#job-priority") |> render() =~ "2"
    assert view |> element("#job-dedupe") |> render() =~ "dedupe-xyz"
  end

  test "shows the payload as pretty JSON", %{conn: conn, fixture: f} do
    QueueFixture.insert_job!(f.queue,
      id: "p1",
      payload_json: %{"source" => "/tmp/synthetic/project", "dry_run" => true}
    )

    {:ok, view, _html} = live(conn, ~p"/jobs/p1")

    payload = view |> element("#job-payload") |> render()
    assert payload =~ "&quot;source&quot;: &quot;/tmp/synthetic/project&quot;"
    assert payload =~ "&quot;dry_run&quot;: true"
  end

  test "shows the mine stdout in a terminal block", %{conn: conn, fixture: f} do
    QueueFixture.insert_job!(f.queue,
      id: "m1",
      state: "succeeded",
      result_json: %{"success" => true, "kind" => "mine", "exit_code" => 0, "stdout" => @stdout}
    )

    {:ok, view, _html} = live(conn, ~p"/jobs/m1")

    stdout = view |> element("#job-stdout") |> render()
    assert stdout =~ "MemPalace Mine"
    assert stdout =~ "+ [1/2] a.md"
    assert stdout =~ "Done."

    # The other result fields stay available without repeating stdout.
    result = view |> element("#job-result") |> render()
    assert result =~ "exit_code"
    refute result =~ "MemPalace Mine"
  end

  test "shows a failed job's error", %{conn: conn, fixture: f} do
    QueueFixture.insert_job!(f.queue,
      id: "e1",
      state: "failed",
      error_json: %{"error_class" => "TypeError", "message" => "synthetic failure"}
    )

    {:ok, view, _html} = live(conn, ~p"/jobs/e1")

    error = view |> element("#job-error") |> render()
    assert error =~ "TypeError"
    assert error =~ "synthetic failure"
    refute has_element?(view, "#job-result")
  end

  test "keeps malformed JSON readable as raw text", %{conn: conn, fixture: f} do
    QueueFixture.insert_job!(f.queue,
      id: "bad",
      payload_json: "{not json",
      error_json: "plain error text"
    )

    {:ok, view, _html} = live(conn, ~p"/jobs/bad")

    assert view |> element("#job-payload") |> render() =~ "{not json"
    assert view |> element("#job-error") |> render() =~ "plain error text"
  end

  test "escapes HTML found in outputs", %{conn: conn, fixture: f} do
    QueueFixture.insert_job!(f.queue,
      id: "x1",
      result_json: %{"stdout" => "<img src=x onerror=alert(1)>"}
    )

    {:ok, _view, html} = live(conn, ~p"/jobs/x1")
    refute html =~ "<img src=x"
    assert html =~ "&lt;img src=x"
  end

  test "does not show sections that have no data", %{conn: conn, fixture: f} do
    QueueFixture.insert_job!(f.queue, id: "q1", state: "queued")

    {:ok, view, _html} = live(conn, ~p"/jobs/q1")

    refute has_element?(view, "#job-error")
    refute has_element?(view, "#job-result")
    refute has_element?(view, "#job-stdout")
  end

  test "refreshes when the queue changes", %{conn: conn, fixture: f} do
    QueueFixture.insert_job!(f.queue, id: "r1", state: "queued")
    {:ok, view, _html} = live(conn, ~p"/jobs/r1")
    assert has_element?(view, "#job-state [data-state=queued]")

    {:ok, db} = Exqlite.Sqlite3.open(f.queue, mode: :readwrite)
    :ok = Exqlite.Sqlite3.execute(db, "UPDATE jobs SET state = 'failed' WHERE id = 'r1'")
    Exqlite.Sqlite3.close(db)
    Phoenix.PubSub.broadcast(Butler.PubSub, Watcher.topic(), {:queue_changed, :x})

    assert render(view) =~ "failed"
    assert has_element?(view, "#job-state [data-state=failed]")
  end

  test "the jobs list links to the detail page", %{conn: conn, fixture: f} do
    QueueFixture.insert_job!(f.queue, id: "link-1")

    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert has_element?(view, ~s(#job-link-1 a[href="/jobs/link-1"]))
  end
end
