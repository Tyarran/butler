defmodule ButlerWeb.PageController do
  @moduledoc """
  Redirects the root path to the daemon status page.
  """
  use ButlerWeb, :controller

  @doc "Redirects `/` to `/daemon`."
  def home(conn, _params), do: redirect(conn, to: ~p"/daemon")
end
