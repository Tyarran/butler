defmodule ButlerWeb.JobsLiveTest do
  use ButlerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Butler.Jobs.Watcher
  alias Butler.Test.DaemonFixture
  alias Butler.Test.QueueFixture

  setup do
    {:ok, fixture: DaemonFixture.install!(running: true)}
  end

  defp finished!(queue, id, kind, seconds, ago \\ 3_000) do
    started = QueueFixture.iso_ago(ago)

    finished =
      DateTime.utc_now()
      |> DateTime.add(-ago + seconds, :second)
      |> DateTime.to_iso8601()
      |> String.replace("Z", "+00:00")

    QueueFixture.insert_job!(queue,
      id: id,
      kind: kind,
      state: "succeeded",
      created_at: started,
      started_at: started,
      finished_at: finished
    )
  end

  test "shows an empty state when there are no jobs", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/jobs")

    assert html =~ "No jobs yet"
    assert html =~ "No active jobs"
    refute has_element?(view, "#active-jobs tr[id]")
  end

  test "shows an empty state without any queue database", %{conn: conn} do
    DaemonFixture.install!(queue: false)
    {:ok, _view, html} = live(conn, ~p"/jobs")
    assert html =~ "No queue database"
  end

  test "lists active jobs in their own section above the history", %{conn: conn, fixture: f} do
    QueueFixture.insert_job!(f.queue,
      id: "run-1",
      state: "running",
      started_at: QueueFixture.iso_ago(125)
    )

    QueueFixture.insert_job!(f.queue, id: "que-1", state: "queued")
    finished!(f.queue, "done-1", "mine", 90)

    {:ok, view, html} = live(conn, ~p"/jobs")

    assert has_element?(view, "#active-jobs #job-run-1")
    assert has_element?(view, "#active-jobs #job-que-1")
    refute has_element?(view, "#active-jobs #job-done-1")
    assert has_element?(view, "#job-history #job-done-1")

    {active_at, _} = :binary.match(html, "active-jobs")
    {history_at, _} = :binary.match(html, "job-history")
    assert active_at < history_at
  end

  test "shows state badges, kind and duration", %{conn: conn, fixture: f} do
    finished!(f.queue, "done-1", "mine", 330)
    QueueFixture.insert_job!(f.queue, id: "bad-1", state: "failed", kind: "mcp_tool")

    {:ok, view, _html} = live(conn, ~p"/jobs")

    row = view |> element("#job-done-1") |> render()
    assert row =~ "succeeded"
    assert row =~ "mine"
    assert row =~ "5m 30s"

    assert view |> element("#job-bad-1") |> render() =~ "failed"
  end

  test "shows the source of a mine job and only the tool name of an mcp_tool job", %{
    conn: conn,
    fixture: f
  } do
    QueueFixture.insert_job!(f.queue,
      id: "m1",
      payload_json: %{"source" => "/tmp/synthetic/project", "mode" => "projects"}
    )

    QueueFixture.insert_job!(f.queue,
      id: "t1",
      kind: "mcp_tool",
      payload_json: %{
        "name" => "mempalace_search",
        "arguments" => %{"query" => "SYNTHETIC-SECRET-ARG"}
      }
    )

    {:ok, view, html} = live(conn, ~p"/jobs")

    assert view |> element("#job-m1") |> render() =~ "/tmp/synthetic/project"
    assert view |> element("#job-t1") |> render() =~ "mempalace_search"
    refute html =~ "SYNTHETIC-SECRET-ARG"
  end

  test "shows the typical duration hint for a running job", %{conn: conn, fixture: f} do
    for {id, secs} <- [{"h1", 240}, {"h2", 300}, {"h3", 360}],
        do: finished!(f.queue, id, "mine", secs)

    QueueFixture.insert_job!(f.queue,
      id: "run-1",
      state: "running",
      started_at: QueueFixture.iso_ago(125)
    )

    {:ok, view, _html} = live(conn, ~p"/jobs")

    assert view |> element("#job-run-1") |> render() =~ "running for 2 min, usual duration ~5 min"
  end

  test "shows no hint without enough history", %{conn: conn, fixture: f} do
    QueueFixture.insert_job!(f.queue,
      id: "run-1",
      state: "running",
      started_at: QueueFixture.iso_ago(125)
    )

    {:ok, view, _html} = live(conn, ~p"/jobs")

    refute view |> element("#job-run-1") |> render() =~ "usual duration"
  end

  test "updates when the watcher broadcasts a change", %{conn: conn, fixture: f} do
    {:ok, view, _html} = live(conn, ~p"/jobs")
    refute has_element?(view, "#job-new-1")

    QueueFixture.insert_job!(f.queue, id: "new-1", state: "queued")
    Phoenix.PubSub.broadcast(Butler.PubSub, Watcher.topic(), {:queue_changed, :ignored})

    assert render(view) =~ "new-1"
    assert has_element?(view, "#active-jobs #job-new-1")
  end

  test "the nav entry is active", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/jobs")
    assert has_element?(view, ~s(a[aria-current="page"]), "Jobs")
  end
end
