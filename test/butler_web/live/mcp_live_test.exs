defmodule ButlerWeb.MCPLiveTest do
  # The MCP subsystem registers global names: no concurrency.
  use ButlerWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Butler.MCP

  @fake Path.expand("../../support/fake_mcp.sh", __DIR__)

  setup do
    previous = Application.fetch_env(:butler, :mcp)

    on_exit(fn ->
      Application.delete_env(:butler, :mcp_demo)

      case previous do
        {:ok, value} -> Application.put_env(:butler, :mcp, value)
        :error -> Application.delete_env(:butler, :mcp)
      end
    end)

    :ok
  end

  defp start_mcp!(opts \\ []) do
    Application.put_env(
      :butler,
      :mcp,
      Keyword.merge(
        [
          idle_rotation_ms: 60_000,
          startup_timeout_ms: 5_000,
          backends: %{full: [bin: @fake], light: [bin: @fake]}
        ],
        opts
      )
    )

    start_supervised!(Butler.MCP.Supervisor)
    MCP.subscribe()
  end

  defp await_status(fun) do
    status = MCP.status()

    if fun.(status) do
      status
    else
      receive do
        {:mcp_changed, _backend} -> await_status(fun)
      after
        5_000 -> flunk("condition never met: #{inspect(status)}")
      end
    end
  end

  test "says so when the proxy is not running", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcp")

    assert has_element?(view, "#mcp-disabled")
    refute has_element?(view, "#backend-full")
  end

  test "is reachable from the navigation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mcp")

    assert has_element?(view, ~s(nav a[href="/mcp"][aria-current="page"]))
  end

  test "shows each backend, its processes, rotation, sessions and requests", %{conn: conn} do
    start_mcp!()
    await_status(fn status -> Enum.all?(status, &(&1.status == :ready)) end)
    {:ok, _json, session} = initialize(:light)
    MCP.handle(:light, session, %{"jsonrpc" => "2.0", "id" => 2, "method" => "ping"})

    {:ok, view, _html} = live(conn, ~p"/mcp")

    for backend <- [:full, :light] do
      assert has_element?(view, "#backend-#{backend}")
      assert has_element?(view, "#status-#{backend}[data-state=ready]")
      assert has_element?(view, "#active-#{backend}")
      assert has_element?(view, "#standby-#{backend}")
      assert has_element?(view, "#rotation-#{backend}")
    end

    assert view |> element("#sessions-light") |> render() =~ ~r/>\s*1\s*</
    assert view |> element("#requests-light") |> render() =~ ~r/>\s*2\s*</
    assert view |> element("#sessions-full") |> render() =~ ~r/>\s*0\s*</
  end

  test "reflects state changes pushed by the proxy", %{conn: conn} do
    start_mcp!()
    {:ok, view, _html} = live(conn, ~p"/mcp")
    await_status(fn status -> Enum.all?(status, &(&1.status == :ready)) end)

    # Rendering after the notification: the page has processed its messages.
    assert render(view) =~ "ready"
    assert has_element?(view, "#status-light[data-state=ready]")
  end

  test "the restart button rotates the backend", %{conn: conn} do
    start_mcp!()
    await_status(fn status -> Enum.all?(status, &(&1.status == :ready)) end)
    {:ok, view, _html} = live(conn, ~p"/mcp")

    view |> element("#btn-restart-light") |> render_click()

    assert [_full, %{id: :light}] = await_status(fn [_full, light] -> light.rotations == 1 end)
    assert render(view) =~ "Restarting light"
  end

  test "shows why a backend failed and lets the user restart it", %{conn: conn} do
    start_mcp!(
      max_start_failures: 1,
      backends: %{full: [bin: @fake], light: [bin: "/nonexistent/butler-test/nope"]}
    )

    await_status(fn [_full, light] -> light.status == :failed end)
    {:ok, view, _html} = live(conn, ~p"/mcp")

    assert has_element?(view, "#status-light[data-state=failed]")
    assert view |> element("#last-error-light") |> render() =~ "executable not found"
    assert has_element?(view, "#btn-restart-light")
  end

  test "shows synthetic data in demo mode", %{conn: conn} do
    Application.put_env(:butler, :mcp_demo, true)

    {:ok, view, _html} = live(conn, ~p"/mcp")

    assert has_element?(view, "#status-full[data-state=ready]")
    assert has_element?(view, "#status-light[data-state=degraded]")

    view |> element("#btn-restart-full") |> render_click()
    assert render(view) =~ "Restarting full"
  end

  defp initialize(backend) do
    case MCP.handle(backend, nil, %{"jsonrpc" => "2.0", "id" => 1, "method" => "initialize"}) do
      {:json, json, session} -> {:ok, json, session}
    end
  end
end
