defmodule Butler.DemoTest do
  use ExUnit.Case, async: false

  import Bitwise

  alias Butler.CLI.Demo, as: DemoCLI
  alias Butler.Demo
  alias Butler.Jobs.DurationHint
  alias Butler.Jobs.Kinds
  alias Butler.Jobs.Store

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    {:ok, demo: Demo.build!(tmp)}
  end

  # Reads through a handle, like the engine does.
  defp read(queue, fun) do
    {:ok, db} = Store.open(queue)

    try do
      fun.(db)
    after
      Store.close(db)
    end
  end

  defp all_jobs(queue) do
    {:ok, jobs} = read(queue, &Store.list(&1, limit: 1_000))
    jobs
  end

  test "builds Butler's own queue in a private state dir", %{demo: demo, tmp_dir: tmp} do
    assert demo.state_dir == Path.join(tmp, "state")
    assert demo.queue == Path.join(demo.state_dir, "queue.sqlite3")
    assert band(File.stat!(demo.state_dir).mode, 0o777) == 0o700
    assert band(File.stat!(demo.queue).mode, 0o777) == 0o600
  end

  test "the queue can be reopened by the engine (schema and version are Butler's)", %{demo: demo} do
    assert {:ok, db} = Store.open(demo.queue)
    Store.close(db)
  end

  test "contains queued and terminal jobs, and no running one", %{demo: demo} do
    assert {:ok, counts} = read(demo.queue, &Store.counts/1)

    for state <- ~w(queued succeeded failed cancelled)a do
      assert counts[state] > 0, "expected at least one #{state} job"
    end

    # A running row would be recovered (or confused with a live job) by the engine.
    assert counts.running == 0
  end

  test "contains every kind shown in the dashboard and enough history for the hint", %{
    demo: demo
  } do
    jobs = all_jobs(demo.queue)
    kinds = jobs |> Enum.map(& &1.kind) |> Enum.uniq() |> Enum.sort()

    assert Enum.all?(~w(mine sweep sync mcp_tool diary_write), &(&1 in kinds))

    queued_mine = Enum.find(jobs, &(&1.kind == "mine" and &1.state == :queued))
    running = %{queued_mine | state: :running, started_at: DateTime.utc_now()}
    assert DurationHint.hint(running, jobs) =~ "usual duration"
  end

  test "every payload is valid for the worker", %{demo: demo} do
    for job <- all_jobs(demo.queue) do
      assert {:ok, _payload} = Kinds.validate_payload(job.kind, job.payload),
             "invalid #{job.kind} payload: #{inspect(job.payload)}"
    end
  end

  test "mine jobs carry an output tail and failed jobs an error", %{demo: demo} do
    jobs = all_jobs(demo.queue)

    mine = Enum.find(jobs, &(&1.kind == "mine" and &1.state == :succeeded))
    assert mine.result["output_tail"] =~ "MemPalace Mine"
    assert mine.payload["source"] =~ "/demo/"

    failed = Enum.find(jobs, &(&1.state == :failed and &1.kind == "mine"))
    assert is_map(failed.error) and is_binary(failed.error["message"])
  end

  test "all content is synthetic: no home directory path leaks into the data", %{demo: demo} do
    jobs = all_jobs(demo.queue)
    dump = inspect(jobs, limit: :infinity, printable_limit: :infinity)

    refute dump =~ System.user_home!()
    refute dump =~ "/home/"
  end

  test "is deterministic apart from timestamps", %{tmp_dir: tmp} do
    first = all_jobs(Demo.build!(Path.join(tmp, "first")).queue)
    second = all_jobs(Demo.build!(Path.join(tmp, "second")).queue)

    assert Enum.map(first, & &1.id) == Enum.map(second, & &1.id)
  end

  describe "Butler.CLI.Demo" do
    setup do
      Application.put_env(:butler, :demo_line_pause_ms, 0)
      on_exit(fn -> Application.delete_env(:butler, :demo_line_pause_ms) end)
    end

    test "never executes anything: it streams canned output" do
      parent = self()

      for args <- [
            ["--palace", "/demo/palace", "mine", "/demo/projects/x", "--direct"],
            ["--palace", "/demo/palace", "sweep", "/demo/t", "--direct"],
            ["--palace", "/demo/palace", "sync", "--direct", "--dry-run"],
            ["--palace", "/demo/palace", "repair", "--yes"],
            ["--palace", "/demo/palace", "compress"]
          ] do
        assert {:ok, %{status: 0, output: output}} =
                 DemoCLI.run(args, on_output: &send(parent, {:line, &1}))

        assert output =~ "demo mode"
        assert_received {:line, _}
      end
    end

    test "an unknown command is refused" do
      assert {:ok, %{status: 2}} = DemoCLI.run(["--palace", "/demo/palace", "rm", "-rf", "/"], [])
    end
  end
end
