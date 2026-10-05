defmodule Butler.Commands.DirectTest do
  use ExUnit.Case, async: false

  import Mox

  alias Butler.Commands.Direct
  alias Butler.Daemon.Status
  alias Butler.Jobs.Job

  @palace "/tmp/synthetic/palace"
  @timeout 2_000

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    previous = Application.fetch_env(:butler, :palace_path)
    Application.put_env(:butler, :palace_path, @palace)

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:butler, :palace_path, value)
        :error -> Application.delete_env(:butler, :palace_path)
      end
    end)

    # The previous test's worker may still be exiting (it broadcasts :done first).
    assert eventually(fn -> Direct.running() == nil end)

    run_id = Direct.new_run_id()
    :ok = Phoenix.PubSub.subscribe(Butler.PubSub, Direct.topic(run_id))
    {:ok, run_id: run_id}
  end

  # A status function returning the given states in order (the last repeats).
  defp statuses(states) do
    {:ok, agent} = Agent.start_link(fn -> states end)

    fn ->
      state =
        Agent.get_and_update(agent, fn
          [last] -> {last, [last]}
          [head | tail] -> {head, tail}
        end)

      %Status{state: state, palace_path: @palace}
    end
  end

  defp opts(run_id, extra \\ []) do
    Keyword.merge(
      [
        run_id: run_id,
        guard: fn -> :ok end,
        status: statuses([:running, :stopped]),
        control_opts: [sleep: fn _ms -> :ok end, poll_ms: 10, max_wait_ms: 50]
      ],
      extra
    )
  end

  defp ok(output \\ ""), do: {:ok, %{status: 0, output: output}}

  # Records the order of CLI calls in an agent, answering with `fun.(args)`.
  defp record_calls(answer) do
    {:ok, calls} = Agent.start_link(fn -> [] end)

    stub(Butler.CLIMock, :run, fn args, opts ->
      Agent.update(calls, &[args | &1])
      answer.(args, opts)
    end)

    calls
  end

  defp verbs(calls), do: calls |> Agent.get(& &1) |> Enum.reverse() |> Enum.map(&Enum.drop(&1, 2))

  defp collect_until_done(run_id, acc \\ []) do
    receive do
      {:direct, ^run_id, {:done, result}} -> {Enum.reverse(acc), result}
      {:direct, ^run_id, event} -> collect_until_done(run_id, [event | acc])
    after
      @timeout -> flunk("run did not finish; events so far: #{inspect(Enum.reverse(acc))}")
    end
  end

  test "commands/0 lists the supported maintenance commands" do
    assert Direct.commands() == [:repair, :compress, :migrate_wings]
  end

  describe "start_run/2 refusals" do
    test "rejects an unknown command", %{run_id: run_id} do
      assert Direct.start_run(:rm_rf, opts(run_id)) == {:error, :unknown_command}
    end

    test "is refused when jobs block, without any CLI call", %{run_id: run_id} do
      jobs = [%Job{id: "r1", state: :running}]

      assert Direct.start_run(:repair, opts(run_id, guard: fn -> {:blocked, jobs} end)) ==
               {:error, {:blocked, jobs}}

      refute_receive {:direct, _, _}, 50
    end

    test "is refused when the queue cannot be checked", %{run_id: run_id} do
      assert Direct.start_run(:repair, opts(run_id, guard: fn -> {:error, :boom} end)) ==
               {:error, {:guard, :boom}}
    end
  end

  describe "a successful run" do
    test "guard, stop, wait, command, restart - in that order", %{run_id: run_id} do
      calls = record_calls(fn _args, _opts -> ok("done\n") end)

      assert {:ok, ^run_id} = Direct.start_run(:compress, opts(run_id))
      {events, result} = collect_until_done(run_id)

      assert result == {:ok, %{status: 0}}

      assert verbs(calls) == [
               ["daemon", "stop"],
               ["compress"],
               ["daemon", "start"]
             ]

      steps = for {:step, step} <- events, do: step
      assert steps == [:stopping, :waiting, :running, :restarting]
      assert {:restart, :ok} in events
    end

    test "uses the palace, a long timeout and never a shell string", %{run_id: run_id} do
      calls = record_calls(fn _args, _opts -> ok() end)

      {:ok, _} = Direct.start_run(:migrate_wings, opts(run_id))
      collect_until_done(run_id)

      for args <- Agent.get(calls, & &1) do
        assert ["--palace", @palace | _] = args
        assert Enum.all?(args, &is_binary/1)
      end
    end

    test "builds the arguments of each command", %{run_id: run_id} do
      calls = record_calls(fn _args, _opts -> ok() end)

      {:ok, _} = Direct.start_run(:repair, opts(run_id, dry_run: true))
      collect_until_done(run_id)
      assert Enum.at(verbs(calls), 1) == ["repair", "--dry-run"]
    end

    test "streams the output lines on the run topic", %{run_id: run_id} do
      record_calls(fn
        ["--palace", _, "daemon", _], _opts ->
          ok()

        _args, cli_opts ->
          cli_opts[:on_output].("first line")
          cli_opts[:on_output].("second line")
          ok("first line\nsecond line\n")
      end)

      {:ok, _} = Direct.start_run(:compress, opts(run_id))
      {events, _result} = collect_until_done(run_id)

      assert for({:line, line} <- events, do: line) == ["first line", "second line"]
    end
  end

  describe "restart after the command" do
    test "restarts the daemon when the command exits non-zero", %{run_id: run_id} do
      calls =
        record_calls(fn
          ["--palace", _, "repair" | _], _ -> {:ok, %{status: 1, output: "failed"}}
          _args, _ -> ok()
        end)

      {:ok, _} = Direct.start_run(:repair, opts(run_id))
      {_events, result} = collect_until_done(run_id)

      assert result == {:error, {:exit_status, 1}}
      assert List.last(verbs(calls)) == ["daemon", "start"]
    end

    test "restarts the daemon when the command times out", %{run_id: run_id} do
      calls =
        record_calls(fn
          ["--palace", _, "compress" | _], _ -> {:error, {:timeout, "partial"}}
          _args, _ -> ok()
        end)

      {:ok, _} = Direct.start_run(:compress, opts(run_id))
      {_events, result} = collect_until_done(run_id)

      assert result == {:error, {:timeout, "partial"}}
      assert List.last(verbs(calls)) == ["daemon", "start"]
    end

    test "restarts the daemon when the command raises", %{run_id: run_id} do
      calls =
        record_calls(fn
          ["--palace", _, "compress" | _], _ -> raise "synthetic crash"
          _args, _ -> ok()
        end)

      {:ok, _} = Direct.start_run(:compress, opts(run_id))
      {_events, result} = collect_until_done(run_id)

      assert {:error, {:exception, message}} = result
      assert message =~ "synthetic crash"
      assert List.last(verbs(calls)) == ["daemon", "start"]
    end

    test "reports a failed restart", %{run_id: run_id} do
      record_calls(fn
        ["--palace", _, "daemon", "start"], _ -> {:ok, %{status: 1, output: "cannot start"}}
        _args, _ -> ok()
      end)

      {:ok, _} = Direct.start_run(:compress, opts(run_id))
      {events, result} = collect_until_done(run_id)

      assert result == {:ok, %{status: 0}}
      assert {:restart, {:error, {:cli, %{status: 1, output: "cannot start"}}}} in events
    end
  end

  describe "safety" do
    test "never runs the command when the daemon does not stop, but still restarts", %{
      run_id: run_id
    } do
      calls = record_calls(fn _args, _ -> ok() end)

      {:ok, _} = Direct.start_run(:repair, opts(run_id, status: statuses([:running])))
      {_events, result} = collect_until_done(run_id)

      assert result == {:error, :stop_timeout}
      assert verbs(calls) == [["daemon", "stop"], ["daemon", "start"]]
    end

    test "aborts and restarts when a job appears after the stop", %{run_id: run_id} do
      calls = record_calls(fn _args, _ -> ok() end)
      {:ok, guard_calls} = Agent.start_link(fn -> 0 end)

      jobs = [%Job{id: "late", state: :queued}]

      guard = fn ->
        case Agent.get_and_update(guard_calls, &{&1, &1 + 1}) do
          0 -> :ok
          _ -> {:blocked, jobs}
        end
      end

      {:ok, _} = Direct.start_run(:repair, opts(run_id, guard: guard))
      {_events, result} = collect_until_done(run_id)

      assert result == {:error, {:blocked, jobs}}
      assert verbs(calls) == [["daemon", "stop"], ["daemon", "start"]]
    end

    test "when the daemon was already stopped, runs the command and leaves it stopped", %{
      run_id: run_id
    } do
      calls = record_calls(fn _args, _ -> ok() end)

      {:ok, _} = Direct.start_run(:compress, opts(run_id, status: statuses([:stopped])))
      {events, result} = collect_until_done(run_id)

      assert result == {:ok, %{status: 0}}
      assert [["compress" | _]] = verbs(calls)
      refute Enum.any?(events, &match?({:restart, _}, &1))
    end

    test "fails without running when stop itself fails", %{run_id: run_id} do
      calls =
        record_calls(fn
          ["--palace", _, "daemon", "stop"], _ -> {:ok, %{status: 1, output: "nope"}}
          _args, _ -> ok()
        end)

      {:ok, _} = Direct.start_run(:repair, opts(run_id))
      {_events, result} = collect_until_done(run_id)

      assert {:error, {:stop_failed, {:cli, %{status: 1}}}} = result
      assert verbs(calls) == [["daemon", "stop"], ["daemon", "start"]]
    end
  end

  describe "concurrency" do
    test "refuses a second run while one is in progress", %{run_id: run_id} do
      test_pid = self()
      {:ok, first_stop?} = Agent.start_link(fn -> true end)

      record_calls(fn
        ["--palace", _, "daemon", "stop"], _ ->
          if Agent.get_and_update(first_stop?, &{&1, false}) do
            send(test_pid, {:worker_blocked, self()})

            receive do
              :continue -> ok()
            end
          else
            ok()
          end

        _args, _ ->
          ok()
      end)

      {:ok, _} = Direct.start_run(:repair, opts(run_id))
      assert_receive {:worker_blocked, worker}, @timeout

      assert Direct.running() == run_id
      assert Direct.start_run(:compress, opts(Direct.new_run_id())) == {:error, :busy}

      send(worker, :continue)
      {_events, result} = collect_until_done(run_id)
      assert result == {:ok, %{status: 0}}

      # The lock is released once the run is over.
      assert eventually(fn -> Direct.running() == nil end)
      next_id = Direct.new_run_id()
      Phoenix.PubSub.subscribe(Butler.PubSub, Direct.topic(next_id))
      assert {:ok, ^next_id} = Direct.start_run(:compress, opts(next_id))
      collect_until_done(next_id)
    end

    test "the lock is released even if the worker is killed", %{run_id: run_id} do
      test_pid = self()

      record_calls(fn
        ["--palace", _, "daemon", "stop"], _ ->
          send(test_pid, {:worker_blocked, self()})
          Process.sleep(:infinity)

        _args, _ ->
          ok()
      end)

      {:ok, _} = Direct.start_run(:repair, opts(run_id))
      assert_receive {:worker_blocked, worker}, @timeout
      Process.exit(worker, :kill)

      assert eventually(fn -> Direct.running() == nil end)
    end
  end

  defp eventually(fun, attempts \\ 40) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(25) && eventually(fun, attempts - 1)
    end
  end
end
