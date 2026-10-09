defmodule Butler.Jobs.Runner.CLITest do
  use ExUnit.Case, async: true

  import Mox

  alias Butler.Jobs.Job
  alias Butler.Jobs.Kinds
  alias Butler.Jobs.Runner.CLI, as: Runner

  setup :verify_on_exit!

  @palace "/tmp/synthetic/palace"
  @mine %Job{id: "j1", kind: "mine", payload: %{"source" => "/tmp/synthetic/src"}}

  defp run(job \\ @mine, opts \\ []), do: Runner.run(job, [palace: @palace] ++ opts)

  test "runs the direct argv with timeout, routing env and the callbacks" do
    on_start = fn _pid -> :ok end

    expect(Butler.CLIMock, :run, fn argv, opts ->
      assert argv == ["--palace", @palace, "mine", "/tmp/synthetic/src", "--direct"]
      assert opts[:timeout] == 1_234
      assert opts[:env] == Kinds.routing_env()
      assert opts[:on_start] == on_start
      assert is_function(opts[:on_output], 1)
      {:ok, %{status: 0, output: "done\n"}}
    end)

    assert {:ok, %{exit_status: 0, output_tail: "done\n"}} =
             run(@mine, timeout_ms: 1_234, on_start: on_start, on_output: fn _ -> :ok end)
  end

  test "a non-zero exit is a CommandFailed error" do
    expect(Butler.CLIMock, :run, fn _argv, _opts -> {:ok, %{status: 2, output: "boom\n"}} end)

    assert {:error, %{class: "CommandFailed", exit_status: 2, output_tail: "boom\n"}} = run()
  end

  test "a timeout is a Timeout error with the partial output" do
    expect(Butler.CLIMock, :run, fn _argv, _opts -> {:error, {:timeout, "partial"}} end)

    assert {:error, %{class: "Timeout", output_tail: "partial", message: "timed out after 3s"}} =
             run(@mine, timeout_ms: 3_000)
  end

  test "a missing executable and other CLI errors" do
    expect(Butler.CLIMock, :run, fn _argv, _opts -> {:error, {:executable_not_found, "x"}} end)
    assert {:error, %{class: "ExecutableNotFound"}} = run()

    expect(Butler.CLIMock, :run, fn _argv, _opts -> {:error, {:invalid_args, []}} end)
    assert {:error, %{class: "CLIError"}} = run()
  end

  test "an invalid payload never reaches the CLI" do
    assert {:error, %{class: "InvalidPayload"}} = run(%Job{kind: "mine", payload: %{}})
    assert {:error, %{class: "InvalidPayload"}} = run(%Job{kind: "bogus", payload: %{}})
    assert {:error, %{class: "InvalidPayload"}} = run(%Job{kind: "mine", payload: nil})
  end

  describe "lock refusal" do
    @refusals [
      # mine / sync (stderr, exit 1)
      {1,
       "mempalace: palace /p is held by PID 12 (/bin/mempalace-mcp --palace /p); wait for it to finish or stop the holder before retrying\n"},
      # sweep file (traceback, exit 1)
      {1,
       "Traceback (most recent call last):\n  ...\nmempalace.palace.MineAlreadyRunning: palace /p is held by PID 1 (x)\n"},
      # sweep dir (exit 2)
      {2,
       "sweeper: sweep failed on a.jsonl: palace /p is held by PID 3 (x); wait for it to finish or stop the holder before retrying\n"},
      # compress / repair (stdout)
      {1,
       "Error storing compressed drawers: palace /p is held by PID 9 (y); wait for it to finish or stop the holder before retrying\n"},
      {1,
       "Repair failed: palace /p is held by PID 9 (y); wait for it to finish or stop the holder before retrying\n"}
    ]

    test "is detected on any exit code and stream when the exit is non-zero" do
      for {status, output} <- @refusals do
        expect(Butler.CLIMock, :run, fn _argv, _opts ->
          {:ok, %{status: status, output: output}}
        end)

        assert {:lock_refused, ^output} = run()
      end
    end

    test "is not a refusal when the command succeeded" do
      output =
        "palace /p is held by PID 1 (x); wait for it to finish or stop the holder before retrying"

      expect(Butler.CLIMock, :run, fn _argv, _opts -> {:ok, %{status: 0, output: output}} end)
      assert {:ok, _} = run()
    end

    test "lock_refused?/1 and the error class" do
      assert Runner.lock_refused?("... MineAlreadyRunning ...")
      refute Runner.lock_refused?("some other failure")
      assert Runner.lock_class() == "LockHeldByOtherProcess"
    end
  end
end
