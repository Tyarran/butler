defmodule ButlerWeb.APICase do
  @moduledoc """
  Test case for the HTTP API: a queue in a throwaway state dir and a `conn`
  that is a loopback client holding Butler's own token.

  Tests are `async: false` (global queue name, application env).
  """

  use ExUnit.CaseTemplate

  alias Butler.Jobs.Queue

  using do
    quote do
      @endpoint ButlerWeb.Endpoint

      use ButlerWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest

      @moduletag :tmp_dir
    end
  end

  setup %{tmp_dir: tmp} do
    previous = Application.fetch_env(:butler, :state_dir)
    Application.put_env(:butler, :state_dir, Path.join(tmp, "state"))

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:butler, :state_dir, value)
        :error -> Application.delete_env(:butler, :state_dir)
      end
    end)

    start_supervised!({Queue, name: Queue, path: Path.join([tmp, "state", "queue.sqlite3"])})
    {:ok, token} = Butler.Token.ensure()

    conn =
      %{Phoenix.ConnTest.build_conn() | host: "localhost"}
      |> Plug.Conn.put_req_header("authorization", "Bearer " <> token)

    {:ok, conn: conn, token: token}
  end
end
