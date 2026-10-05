defmodule Butler.Test.DaemonFixture do
  @moduledoc """
  Installs a fake MemPalace home (synthetic data only) and points the `:butler`
  application environment to it, restoring the previous values on exit.

  Tests using this fixture mutate global application env and must therefore
  not be `async: true`.
  """

  alias Butler.Daemon.Locator
  alias Butler.Test.QueueFixture

  @palace "/tmp/synthetic/palace"
  @dead_pid 2_147_000_000

  @type t :: %{home: Path.t(), palace: Path.t(), dir: Path.t(), queue: Path.t()}

  @doc """
  Creates `<home>/daemon/<key>/` with an empty queue.

  Options:

    * `:running` - `true` writes an `endpoint.json` with the pid of the test
      VM (alive); `false` (default) writes none, like a cleanly stopped daemon;
      `:stale` writes an endpoint with a dead pid.
    * `:queue` - `false` to skip creating the queue database.
  """
  @spec install!(keyword()) :: t()
  def install!(opts \\ []) do
    home = QueueFixture.tmp_dir!()
    dir = Path.join([home, "daemon", Locator.palace_key(@palace)])
    File.mkdir_p!(dir)
    queue = Path.join(dir, "queue.sqlite3")
    if Keyword.get(opts, :queue, true), do: QueueFixture.create!(queue)

    case Keyword.get(opts, :running, false) do
      false -> :ok
      true -> write_endpoint!(dir, String.to_integer(System.pid()))
      :stale -> write_endpoint!(dir, @dead_pid)
    end

    put_env!(palace_path: @palace, mempalace_home: home)
    %{home: home, palace: @palace, dir: dir, queue: queue}
  end

  @doc "The synthetic palace path used by the fixture."
  @spec palace() :: Path.t()
  def palace, do: @palace

  @doc "Sets application env keys, restoring the previous values on test exit."
  @spec put_env!(keyword()) :: :ok
  def put_env!(pairs) do
    previous = Enum.map(pairs, fn {key, _} -> {key, Application.fetch_env(:butler, key)} end)

    ExUnit.Callbacks.on_exit(fn ->
      for {key, result} <- previous do
        case result do
          {:ok, value} -> Application.put_env(:butler, key, value)
          :error -> Application.delete_env(:butler, key)
        end
      end
    end)

    Enum.each(pairs, fn {key, value} -> Application.put_env(:butler, key, value) end)
  end

  defp write_endpoint!(dir, pid) do
    File.write!(
      Path.join(dir, "endpoint.json"),
      Jason.encode!(%{
        "host" => "127.0.0.1",
        "port" => 4242,
        "pid" => pid,
        "palace_path" => @palace,
        "started_at" =>
          DateTime.utc_now() |> DateTime.add(-3_700, :second) |> DateTime.to_iso8601()
      })
    )
  end
end
