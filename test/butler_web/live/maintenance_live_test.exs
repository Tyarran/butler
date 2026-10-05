defmodule ButlerWeb.MaintenanceLiveTest do
  use ButlerWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  alias Butler.Commands.Direct
  alias Butler.Daemon.Status
  alias Butler.Test.DaemonFixture
  alias Butler.Test.QueueFixture

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    assert eventually(fn -> Direct.running() == nil end)
    {:ok, fixture: DaemonFixture.install!(running: false)}
  end

  defp ok(output \\ ""), do: {:ok, %{status: 0, output: output}}

  defp eventually(fun, attempts \\ 80) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(25) && eventually(fun, attempts - 1)
    end
  end

  test "lists the three commands and is in the navigation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/maintenance")

    for command <- ~w(repair compress migrate_wings) do
      assert has_element?(view, "#run-#{command}")
      assert has_element?(view, "#dry-#{command}")
    end

    assert has_element?(view, ~s(nav a[href="/maintenance"][aria-current="page"]))
  end

  test "asks for confirmation and explains what will happen", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/maintenance")
    view |> element("#run-repair") |> render_click()

    dialog = view |> element("#confirm-dialog") |> render()
    assert dialog =~ "repair"
    assert dialog =~ "stop the daemon"
    assert dialog =~ "restart"
    # Nothing ran: no CLI expectation was registered.
  end

  test "cancelling the confirmation closes it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/maintenance")
    view |> element("#run-repair") |> render_click()
    view |> element("#confirm-cancel") |> render_click()

    refute has_element?(view, "#confirm-dialog")
  end

  test "streams the command output in a terminal", %{conn: conn, fixture: f} do
    expect(Butler.CLIMock, :run, fn args, opts ->
      assert args == ["--palace", f.palace, "compress"]
      opts[:on_output].("compressing wing synthetic")
      opts[:on_output].("all done")
      ok("compressing wing synthetic\nall done\n")
    end)

    {:ok, view, _html} = live(conn, ~p"/maintenance")
    view |> element("#run-compress") |> render_click()
    view |> element("#confirm-ok") |> render_click()

    assert eventually(fn -> render(view) =~ "all done" end)
    terminal = view |> element("#direct-output") |> render()
    assert terminal =~ "compressing wing synthetic"
    assert terminal =~ "all done"
    assert eventually(fn -> has_element?(view, "#direct-result [data-state=succeeded]") end)
  end

  test "a dry run passes --dry-run", %{conn: conn} do
    expect(Butler.CLIMock, :run, fn args, _opts ->
      assert List.last(args) == "--dry-run"
      ok()
    end)

    {:ok, view, _html} = live(conn, ~p"/maintenance")
    view |> element("#dry-migrate_wings") |> render_click()
    view |> element("#confirm-ok") |> render_click()

    assert eventually(fn -> has_element?(view, "#direct-result") end)
  end

  test "reports a failing command", %{conn: conn} do
    expect(Butler.CLIMock, :run, fn _args, _opts -> {:ok, %{status: 3, output: "boom"}} end)

    {:ok, view, _html} = live(conn, ~p"/maintenance")
    view |> element("#run-compress") |> render_click()
    view |> element("#confirm-ok") |> render_click()

    assert eventually(fn -> has_element?(view, "#direct-result [data-state=failed]") end)
    assert view |> element("#direct-result") |> render() =~ "exit status 3"
  end

  test "is refused while jobs block, listing them", %{conn: conn, fixture: f} do
    QueueFixture.insert_job!(f.queue, id: "blocking-job-1", state: "running")

    {:ok, view, _html} = live(conn, ~p"/maintenance")
    view |> element("#run-repair") |> render_click()
    view |> element("#confirm-ok") |> render_click()

    refusal = view |> element("#direct-refusal") |> render()
    assert refusal =~ "blocking-"
    assert has_element?(view, ~s(#direct-refusal a[href="/jobs/blocking-job-1"]))
    refute has_element?(view, "#direct-output")
  end

  test "stops and restarts a running daemon around the command", %{conn: conn} do
    DaemonFixture.install!(running: true)
    {:ok, agent} = Agent.start_link(fn -> [:running, :stopped] end)

    status = fn ->
      state =
        Agent.get_and_update(agent, fn
          [last] -> {last, [last]}
          [head | tail] -> {head, tail}
        end)

      %Status{state: state, palace_path: DaemonFixture.palace()}
    end

    DaemonFixture.put_env!(
      direct_opts: [
        status: status,
        control_opts: [sleep: fn _ -> :ok end, poll_ms: 5, max_wait_ms: 50]
      ]
    )

    Butler.CLIMock
    |> expect(:run, fn [_, _, "daemon", "stop"], _ -> ok() end)
    |> expect(:run, fn [_, _, "compress"], _ -> ok("compressed\n") end)
    |> expect(:run, fn [_, _, "daemon", "start"], _ -> ok() end)

    {:ok, view, _html} = live(conn, ~p"/maintenance")
    view |> element("#run-compress") |> render_click()
    view |> element("#confirm-ok") |> render_click()

    assert eventually(fn -> has_element?(view, "#direct-result [data-state=succeeded]") end)
    assert view |> element("#direct-steps") |> render() =~ "restarting"
  end
end
