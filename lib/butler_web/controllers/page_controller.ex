defmodule ButlerWeb.PageController do
  @moduledoc """
  Redirects the root path to the worker status page.
  """
  use ButlerWeb, :controller

  @doc "Redirects `/` to `/worker`."
  def home(conn, _params), do: redirect(conn, to: ~p"/worker")
end
