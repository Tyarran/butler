defmodule ButlerWeb.DaemonLiveTest do
  use ButlerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Butler.Jobs.Watcher
  alias Butler.Test.DaemonFixture
  alias Butler.Test.QueueFixture

  test "/ redirects to /daemon", %{conn: conn} do
    assert redirected_to(get(conn, ~p"/")) == ~p"/daemon"
  end

  describe "running daemon" do
    setup do
      {:ok, fixture: DaemonFixture.install!(running: true)}
    end

    test "shows the running badge, PID and palace", %{conn: conn, fixture: fixture} do
      {:ok, view, html} = live(conn, ~p"/daemon")

      assert has_element?(view, "#daemon-state [data-state=running]")
      assert html =~ System.pid()
      assert html =~ fixture.palace
      assert html =~ "Started"
    end

    test "shows the job counters", %{conn: conn, fixture: fixture} do
      for state <- ~w(queued running running succeeded failed failed failed cancelled) do
        QueueFixture.insert_job!(fixture.queue, state: state)
      end

      {:ok, view, _html} = live(conn, ~p"/daemon")

      for {state, count} <- [queued: 1, running: 2, succeeded: 1, failed: 3, cancelled: 1] do
        assert view |> element("#count-#{state}") |> render() =~ ~r/>\s*#{count}\s*</
      end
    end

    test "refreshes when the watcher broadcasts a change", %{conn: conn, fixture: fixture} do
      {:ok, view, _html} = live(conn, ~p"/daemon")
      assert view |> element("#count-failed") |> render() =~ ~r/>\s*0\s*</

      QueueFixture.insert_job!(fixture.queue, state: "failed")
      Phoenix.PubSub.broadcast(Butler.PubSub, Watcher.topic(), {:queue_changed, :ignored})

      assert render(view) =~ "daemon"
      assert view |> element("#count-failed") |> render() =~ ~r/>\s*1\s*/
    end
  end

  describe "stopped daemon" do
    test "shows the stopped badge and still shows the queue counters", %{conn: conn} do
      fixture = DaemonFixture.install!(running: false)
      QueueFixture.insert_job!(fixture.queue, state: "succeeded")

      {:ok, view, html} = live(conn, ~p"/daemon")

      assert has_element?(view, "#daemon-state [data-state=stopped]")
      assert html =~ "The daemon is stopped"
      assert view |> element("#count-succeeded") |> render() =~ ~r/>\s*1\s*</
    end

    test "a stale endpoint (dead PID) is shown as stopped", %{conn: conn} do
      DaemonFixture.install!(running: :stale)
      {:ok, view, _html} = live(conn, ~p"/daemon")
      assert has_element?(view, "#daemon-state [data-state=stopped]")
    end

    test "without any queue database it says so", %{conn: conn} do
      DaemonFixture.install!(running: false, queue: false)
      {:ok, view, html} = live(conn, ~p"/daemon")

      assert html =~ "No queue database"
      refute has_element?(view, "#count-failed")
    end
  end

  test "renders inside the app layout with the Daemon entry active", %{conn: conn} do
    DaemonFixture.install!()
    {:ok, _view, html} = live(conn, ~p"/daemon")

    assert html =~ ~s(aria-current="page")
    assert html =~ ~s(data-phx-theme="dark")
  end
end
