defmodule ButlerWeb.ErrorJSONTest do
  use ButlerWeb.ConnCase, async: true

  test "renders 404" do
    assert %{error: %{code: "not_found"}} = ButlerWeb.ErrorJSON.render("404.json", %{})
  end

  test "renders 500" do
    assert ButlerWeb.ErrorJSON.render("500.json", %{}) ==
             %{errors: %{detail: "Internal Server Error"}}
  end
end
