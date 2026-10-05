defmodule Butler.DemoTest do
  use ExUnit.Case, async: false

  alias Butler.CLI.Demo, as: DemoCLI
  alias Butler.Daemon.Locator
  alias Butler.Daemon.Status
  alias Butler.Demo
  alias Butler.Jobs.DurationHint
  alias Butler.Jobs.Store
  alias Butler.Test.DaemonFixture
  alias Butler.Test.QueueFixture
  alias Exqlite.Sqlite3

  setup do
    dir = QueueFixture.tmp_dir!()
    {:ok, demo: Demo.build!(dir), dir: dir}
  end

  defp schema(path) do
    {:ok, db} = Sqlite3.open(path, mode: :readonly)

    {:ok, stmt} =
      Sqlite3.prepare(
        db,
        "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name"
      )

    {:ok, rows} = Sqlite3.fetch_all(db, stmt)
    Sqlite3.release(db, stmt)
    Sqlite3.close(db)
    rows
  end

  test "builds a queue with the exact daemon schema", %{demo: demo} do
    reference = QueueFixture.create!(Path.join(QueueFixture.tmp_dir!(), "queue.sqlite3"))

    normalize = fn rows ->
      Enum.map(rows, fn [type, name, sql] -> [type, name, String.replace(sql, ~r/\s+/, " ")] end)
    end

    assert normalize.(schema(demo.queue)) == normalize.(schema(reference))
  end

  test "the demo palace is synthetic and the queue lives in the keyed daemon directory", %{
    demo: demo,
    dir: dir
  } do
    assert demo.palace == "/demo/palace"
    assert Path.dirname(demo.queue) == Path.join([dir, "daemon", Locator.palace_key(demo.palace)])
  end

  test "contains jobs in every state, with a running one", %{demo: demo} do
    assert {:ok, counts} = Store.counts(demo.queue)

    for state <- ~w(queued running succeeded failed cancelled)a do
      assert counts[state] > 0, "expected at least one #{state} job"
    end
  end

  test "contains both job kinds and enough history for the duration hint", %{demo: demo} do
    {:ok, jobs} = Store.list(demo.queue, limit: 1_000)
    kinds = jobs |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()

    assert "mine" in kinds and "mcp_tool" in kinds

    running = Enum.find(jobs, &(&1.state == :running))
    assert DurationHint.hint(running, jobs) =~ "usual duration"
  end

  test "mine jobs carry a report and failed jobs an error", %{demo: demo} do
    {:ok, jobs} = Store.list(demo.queue, limit: 1_000)

    mine = Enum.find(jobs, &(&1.kind == "mine" and &1.state == :succeeded))
    assert mine.result["stdout"] =~ "MemPalace Mine"
    assert mine.payload["source"] =~ "/demo/"

    failed = Enum.find(jobs, &(&1.state == :failed))
    assert is_map(failed.error) and is_binary(failed.error["message"])
  end

  test "all content is synthetic: no home directory path leaks into the data", %{demo: demo} do
    {:ok, jobs} = Store.list(demo.queue, limit: 1_000)
    dump = inspect(jobs, limit: :infinity, printable_limit: :infinity)

    refute dump =~ System.user_home!()
    refute dump =~ "/home/"
  end

  test "is deterministic apart from timestamps", %{dir: dir} do
    other = Demo.build!(Path.join(dir, "second"))
    {:ok, first} = Store.list(Demo.build!(Path.join(dir, "first")).queue, limit: 1_000)
    {:ok, second} = Store.list(other.queue, limit: 1_000)

    assert Enum.map(first, & &1.id) == Enum.map(second, & &1.id)
  end

  test "the daemon appears running with this VM's pid", %{demo: demo, dir: dir} do
    status = Status.resolve(root: Path.join(dir, "daemon"), palace_path: demo.palace)

    assert status.state == :running
    assert status.pid == String.to_integer(System.pid())
  end

  describe "Butler.CLI.Demo" do
    setup %{demo: demo, dir: dir} do
      DaemonFixture.put_env!(
        palace_path: demo.palace,
        mempalace_home: dir,
        daemon_state_root: nil
      )

      :ok
    end

    test "never executes anything: it only answers canned outputs" do
      assert {:ok, %{status: 0, output: "Submitted daemon job " <> _}} =
               DemoCLI.run(
                 [
                   "--palace",
                   "/demo/palace",
                   "mine",
                   "/demo/projects/x",
                   "--daemon",
                   "--background"
                 ],
                 []
               )

      assert {:ok, %{status: 0}} =
               DemoCLI.run(["--palace", "/demo/palace", "sweep", "/demo/t", "--daemon"], [])

      assert {:ok, %{status: 0}} = DemoCLI.run(["--palace", "/demo/palace", "compress"], [])
    end

    test "streams lines for direct commands" do
      parent = self()

      assert {:ok, %{status: 0}} =
               DemoCLI.run(["--palace", "/demo/palace", "repair", "--dry-run"],
                 on_output: &send(parent, {:line, &1})
               )

      assert_received {:line, _}
    end

    test "daemon stop and start flip the daemon state", %{demo: demo, dir: dir} do
      resolve = fn ->
        Status.resolve(root: Path.join(dir, "daemon"), palace_path: demo.palace).state
      end

      assert resolve.() == :running
      assert {:ok, %{status: 0}} = DemoCLI.run(["--palace", demo.palace, "daemon", "stop"], [])
      assert resolve.() == :stopped
      assert {:ok, %{status: 0}} = DemoCLI.run(["--palace", demo.palace, "daemon", "start"], [])
      assert resolve.() == :running
    end

    test "an unknown command is refused" do
      assert {:ok, %{status: 2}} = DemoCLI.run(["--palace", "/demo/palace", "rm", "-rf", "/"], [])
    end
  end
end
