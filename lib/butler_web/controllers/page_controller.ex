defmodule ButlerWeb.PageController do
  use ButlerWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
