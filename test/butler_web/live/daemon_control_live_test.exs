defmodule ButlerWeb.DaemonControlLiveTest do
  use ButlerWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Butler.Daemon.Status
  alias Butler.Test.DaemonFixture

  # LiveView actions run in a separate process, so Mox must be global.
  setup :set_mox_global
  setup :verify_on_exit!

  defp ok(output \\ ""), do: {:ok, %{status: 0, output: output}}

  defp stopped_status, do: fn -> %Status{state: :stopped, palace_path: DaemonFixture.palace()} end

  describe "stopped daemon" do
    setup do
      DaemonFixture.install!(running: false)
      :ok
    end

    test "offers Start only", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/daemon")

      assert has_element?(view, "#btn-start")
      refute has_element?(view, "#btn-stop")
      refute has_element?(view, "#btn-restart")
    end

    test "Start runs `daemon start` without confirmation and reports it", %{conn: conn} do
      expect(Butler.CLIMock, :run, fn ["--palace", palace, "daemon", "start"], opts ->
        assert palace == DaemonFixture.palace()
        assert is_integer(opts[:timeout])
        ok("MemPalace daemon running on 127.0.0.1:4242\n")
      end)

      {:ok, view, _html} = live(conn, ~p"/daemon")
      view |> element("#btn-start") |> render_click()

      html = render_async(view)
      assert html =~ "Daemon started"
      assert html =~ "MemPalace daemon running on 127.0.0.1:4242"
    end

    test "a CLI failure is reported as an error with its output", %{conn: conn} do
      expect(Butler.CLIMock, :run, fn _args, _opts ->
        {:ok, %{status: 1, output: "address already in use"}}
      end)

      {:ok, view, _html} = live(conn, ~p"/daemon")
      view |> element("#btn-start") |> render_click()

      html = render_async(view)
      assert html =~ "Could not start the daemon"
      assert html =~ "address already in use"
    end

    test "a timeout is reported", %{conn: conn} do
      expect(Butler.CLIMock, :run, fn _args, _opts -> {:error, {:timeout, "partial"}} end)

      {:ok, view, _html} = live(conn, ~p"/daemon")
      view |> element("#btn-start") |> render_click()

      assert render_async(view) =~ "timed out"
    end
  end

  describe "running daemon" do
    setup do
      DaemonFixture.install!(running: true)
      DaemonFixture.put_env!(control_opts: [status: stopped_status(), sleep: fn _ -> :ok end])
      :ok
    end

    test "offers Stop and Restart, not Start", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/daemon")

      assert has_element?(view, "#btn-stop")
      assert has_element?(view, "#btn-restart")
      refute has_element?(view, "#btn-start")
    end

    test "Stop asks for confirmation first, explaining the drain and cancellation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/daemon")
      view |> element("#btn-stop") |> render_click()

      dialog = view |> element("#confirm-dialog") |> render()
      assert dialog =~ "10 seconds"
      assert dialog =~ "cancelled"
      assert dialog =~ "not resumed automatically"
      # No CLI expectation was set: any call would have raised.
    end

    test "cancelling the confirmation closes the dialog without any call", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/daemon")
      view |> element("#btn-stop") |> render_click()
      view |> element("#confirm-cancel") |> render_click()

      refute has_element?(view, "#confirm-dialog")
    end

    test "confirming Stop runs `daemon stop`", %{conn: conn} do
      expect(Butler.CLIMock, :run, fn ["--palace", _, "daemon", "stop"], _ ->
        ok("MemPalace daemon stopping\n")
      end)

      {:ok, view, _html} = live(conn, ~p"/daemon")
      view |> element("#btn-stop") |> render_click()
      view |> element("#confirm-ok") |> render_click()

      html = render_async(view)
      assert html =~ "Daemon stopped"
      refute has_element?(view, "#confirm-dialog")
    end

    test "confirming Restart stops then starts", %{conn: conn} do
      Butler.CLIMock
      |> expect(:run, fn ["--palace", _, "daemon", "stop"], _ -> ok() end)
      |> expect(:run, fn ["--palace", _, "daemon", "start"], _ -> ok("started\n") end)

      {:ok, view, _html} = live(conn, ~p"/daemon")
      view |> element("#btn-restart") |> render_click()
      assert view |> element("#confirm-dialog") |> render() =~ "Restart the daemon"
      view |> element("#confirm-ok") |> render_click()

      assert render_async(view) =~ "Daemon restarted"
    end

    test "a restart that never stops reports the error and does not start", %{conn: conn} do
      DaemonFixture.put_env!(
        control_opts: [
          status: fn -> %Status{state: :running, palace_path: DaemonFixture.palace()} end,
          sleep: fn _ -> :ok end,
          poll_ms: 10,
          max_wait_ms: 30
        ]
      )

      expect(Butler.CLIMock, :run, 1, fn ["--palace", _, "daemon", "stop"], _ -> ok() end)

      {:ok, view, _html} = live(conn, ~p"/daemon")
      view |> element("#btn-restart") |> render_click()
      view |> element("#confirm-ok") |> render_click()

      assert render_async(view) =~ "did not stop in time"
    end
  end
end
