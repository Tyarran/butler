defmodule ButlerWeb.PageControllerTest do
  use ButlerWeb.ConnCase

  describe "app layout" do
    test "renders the sidebar navigation with the active entry", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "Butler"
      assert html =~ ~s(aria-label="Main")
      assert html =~ ~s(aria-current="page")
    end

    test "renders a system, light and dark theme toggle", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      for theme <- ~w(system light dark) do
        assert html =~ ~s(data-phx-theme="#{theme}")
      end
    end

    test "applies the stored theme before page load", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)

      assert html =~ "localStorage.getItem(\"phx:theme\")"
      assert html =~ "prefers-color-scheme: dark"
    end

    test "has a page title suffix", %{conn: conn} do
      html = conn |> get(~p"/") |> html_response(200)
      assert html =~ "<title"
      refute html =~ "Phoenix Framework"
    end
  end
end
