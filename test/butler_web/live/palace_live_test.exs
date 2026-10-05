defmodule ButlerWeb.PalaceLiveTest do
  use ButlerWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "shows a coming soon placeholder", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/palace")

    assert html =~ "Coming soon"
    assert has_element?(view, "#palace-placeholder")
  end

  test "is reachable from the navigation", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/palace")

    assert has_element?(view, ~s(nav a[href="/palace"][aria-current="page"]))
  end
end
