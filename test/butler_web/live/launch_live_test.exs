defmodule ButlerWeb.LaunchLiveTest do
  use ButlerWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Butler.Test.DaemonFixture
  alias Butler.Test.QueueFixture

  @job_id "0d500eb9b28b411bb8fc0e4a3f15cecb"

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    {:ok, fixture: DaemonFixture.install!(running: true), project: QueueFixture.tmp_dir!()}
  end

  defp submitted(kind \\ "mine"),
    do: {:ok, %{status: 0, output: "Submitted daemon job #{@job_id} (#{kind})\n"}}

  describe "mine form" do
    test "renders the fields and the nav entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/launch")

      assert has_element?(view, "#mine-form")

      for field <-
            ~w(dir mode wing agent dry_run limit no_gitignore include_ignored extract max_chunks_per_file redetect_origin) do
        assert has_element?(view, "#mine-form [name='mine[#{field}]']"), "missing field #{field}"
      end

      assert has_element?(view, ~s(nav a[href="/launch"][aria-current="page"]))
    end

    test "offers the whitelisted modes and extract strategies", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/launch")

      mode = view |> element("#mine-form select[name='mine[mode]']") |> render()
      for value <- ~w(projects convos extract), do: assert(mode =~ value)

      extract = view |> element("#mine-form select[name='mine[extract]']") |> render()
      for value <- ~w(exchange general), do: assert(extract =~ value)
    end

    test "shows validation errors and does not call the CLI", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/launch")

      html =
        view
        |> form("#mine-form", mine: %{dir: "relative/dir", limit: "0"})
        |> render_submit()

      assert html =~ "must be an absolute path"
      assert html =~ "must be a positive integer"
      refute has_element?(view, "#submit-result")
    end

    test "submits and links to the job", %{conn: conn, fixture: f, project: project} do
      expect(Butler.CLIMock, :run, fn args, _opts ->
        assert args == [
                 "--palace",
                 f.palace,
                 "mine",
                 project,
                 "--daemon",
                 "--background",
                 "--mode",
                 "convos",
                 "--wing",
                 "synthetic",
                 "--dry-run",
                 "--limit",
                 "3"
               ]

        submitted()
      end)

      {:ok, view, _html} = live(conn, ~p"/launch")

      view
      |> form("#mine-form",
        mine: %{dir: project, mode: "convos", wing: "synthetic", dry_run: "true", limit: "3"}
      )
      |> render_submit()

      assert has_element?(view, "#submit-result", "Job submitted")
      assert has_element?(view, ~s(#submit-result a[href="/jobs/#{@job_id}"]))
    end

    test "explains a duplicate with a clear message and a link", %{
      conn: conn,
      fixture: f,
      project: project
    } do
      QueueFixture.insert_job!(f.queue,
        id: "existing-job",
        state: "running",
        payload_json: %{"source" => project, "mode" => "projects"}
      )

      {:ok, view, _html} = live(conn, ~p"/launch")
      view |> form("#mine-form", mine: %{dir: project}) |> render_submit()

      assert has_element?(view, "#submit-result", "An identical job is already queued or running")
      assert has_element?(view, ~s(#submit-result a[href="/jobs/existing-job"]))
    end

    test "shows the CLI output when the submission fails", %{conn: conn, project: project} do
      expect(Butler.CLIMock, :run, fn _args, _opts ->
        {:ok, %{status: 2, output: "mempalace: error: synthetic failure\n"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/launch")
      view |> form("#mine-form", mine: %{dir: project}) |> render_submit()

      assert has_element?(view, "#submit-result", "Submission failed")
      assert view |> element("#submit-output") |> render() =~ "synthetic failure"
    end
  end

  describe "sweep form" do
    test "validates the target", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/launch")

      html = view |> form("#sweep-form", sweep: %{target: ""}) |> render_submit()

      assert html =~ "can&#39;t be blank"
      refute has_element?(view, "#submit-result")
    end

    test "submits a sweep and links to the job", %{conn: conn, fixture: f, project: project} do
      expect(Butler.CLIMock, :run, fn args, _opts ->
        assert args == ["--palace", f.palace, "sweep", project, "--daemon", "--background"]
        submitted("sweep")
      end)

      {:ok, view, _html} = live(conn, ~p"/launch")
      view |> form("#sweep-form", sweep: %{target: project}) |> render_submit()

      assert has_element?(view, ~s(#submit-result a[href="/jobs/#{@job_id}"]))
    end
  end

  describe "sync form" do
    test "is labelled as dry run only and has no apply option", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/launch")

      assert has_element?(view, "#sync-dry-run-only", "Dry run only")
      refute has_element?(view, "#sync-form [name*='apply']")
      refute has_element?(view, "#sync-form [name*='dry_run']")
      refute html =~ "--apply"
    end

    test "always submits --dry-run", %{conn: conn, fixture: f} do
      expect(Butler.CLIMock, :run, fn args, _opts ->
        assert args == ["--palace", f.palace, "sync", "--daemon", "--background", "--dry-run"]
        submitted("sync")
      end)

      {:ok, view, _html} = live(conn, ~p"/launch")
      view |> form("#sync-form", sync: %{wing: ""}) |> render_submit()

      assert has_element?(view, ~s(#submit-result a[href="/jobs/#{@job_id}"]))
    end

    test "passes the wing and roots", %{conn: conn, project: project} do
      expect(Butler.CLIMock, :run, fn args, _opts ->
        assert Enum.drop(args, 5) == ["--dry-run", "--wing", "synthetic", "--root", project]

        submitted("sync")
      end)

      {:ok, view, _html} = live(conn, ~p"/launch")
      view |> form("#sync-form", sync: %{wing: "synthetic", roots: project}) |> render_submit()

      assert has_element?(view, "#submit-result", "Job submitted")
    end

    test "validates roots", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/launch")

      html = view |> form("#sync-form", sync: %{roots: "rel/dir"}) |> render_submit()

      assert html =~ "must be an absolute path"
    end
  end
end
