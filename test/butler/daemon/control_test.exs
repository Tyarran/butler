defmodule Butler.Daemon.ControlTest do
  use ExUnit.Case, async: false

  import Mox

  alias Butler.Daemon.Control
  alias Butler.Daemon.Status

  @palace "/tmp/synthetic/palace"

  setup :set_mox_from_context
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
  end

  defp ok(output \\ ""), do: {:ok, %{status: 0, output: output}}

  # A status function returning the given states in order (the last one repeats).
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

  defp opts(extra \\ []) do
    Keyword.merge([sleep: fn _ms -> :ok end, poll_ms: 10, max_wait_ms: 100], extra)
  end

  describe "start/1" do
    test "runs `daemon start` for the configured palace" do
      expect(Butler.CLIMock, :run, fn args, _opts ->
        assert args == ["--palace", @palace, "daemon", "start"]
        ok("MemPalace daemon running on 127.0.0.1:1234\n")
      end)

      assert Control.start(opts()) == {:ok, "MemPalace daemon running on 127.0.0.1:1234\n"}
    end

    test "returns the output on a non-zero exit" do
      expect(Butler.CLIMock, :run, fn _args, _opts -> {:ok, %{status: 1, output: "boom"}} end)

      assert Control.start(opts()) == {:error, {:cli, %{status: 1, output: "boom"}}}
    end

    test "passes the runner error through" do
      expect(Butler.CLIMock, :run, fn _args, _opts -> {:error, {:timeout, "partial"}} end)

      assert Control.start(opts()) == {:error, {:timeout, "partial"}}
    end

    test "always uses a timeout" do
      expect(Butler.CLIMock, :run, fn _args, cli_opts ->
        assert is_integer(cli_opts[:timeout]) and cli_opts[:timeout] > 0
        ok()
      end)

      assert {:ok, _} = Control.start(opts())
    end
  end

  describe "stop/1" do
    test "runs `daemon stop`, which succeeds even when already stopped" do
      expect(Butler.CLIMock, :run, fn args, _opts ->
        assert args == ["--palace", @palace, "daemon", "stop"]
        ok("MemPalace daemon is not running\n")
      end)

      assert {:ok, _} = Control.stop(opts())
    end
  end

  describe "wait_stopped/1" do
    test "returns as soon as the daemon is stopped" do
      assert Control.wait_stopped(opts(status: statuses([:running, :running, :stopped]))) == :ok
    end

    test "gives up after the capped wait" do
      assert Control.wait_stopped(opts(status: statuses([:running]))) == {:error, :stop_timeout}
    end

    test "polls at the configured interval" do
      parent = self()

      assert Control.wait_stopped(
               opts(
                 status: statuses([:running, :stopped]),
                 poll_ms: 77,
                 sleep: &send(parent, {:slept, &1})
               )
             ) == :ok

      assert_received {:slept, 77}
    end
  end

  describe "restart/1" do
    test "stops, waits for the stop, then starts, in that order" do
      parent = self()

      Butler.CLIMock
      |> expect(:run, fn ["--palace", _, "daemon", "stop"], _ ->
        send(parent, :stopped_cmd)
        ok()
      end)
      |> expect(:run, fn ["--palace", _, "daemon", "start"], _ ->
        assert_received :stopped_cmd
        ok("started")
      end)

      assert {:ok, "started"} =
               Control.restart(opts(status: statuses([:running, :stopped])))
    end

    test "does not start when the daemon never stops" do
      expect(Butler.CLIMock, :run, 1, fn ["--palace", _, "daemon", "stop"], _ -> ok() end)

      assert Control.restart(opts(status: statuses([:running]))) == {:error, :stop_timeout}
    end

    test "does not start when stop fails" do
      expect(Butler.CLIMock, :run, 1, fn _args, _ -> {:ok, %{status: 2, output: "no"}} end)

      assert {:error, {:cli, %{status: 2}}} = Control.restart(opts(status: statuses([:stopped])))
    end
  end
end
