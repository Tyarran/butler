defmodule Butler.CLITest do
  use ExUnit.Case, async: true

  import Mox

  alias Butler.CLI

  setup :verify_on_exit!

  test "run/2 delegates to the configured implementation" do
    expect(Butler.CLIMock, :run, fn ["daemon", "status"], [timeout: 1_000] ->
      {:ok, %{status: 0, output: "MemPalace daemon is running\n"}}
    end)

    assert CLI.run(["daemon", "status"], timeout: 1_000) ==
             {:ok, %{status: 0, output: "MemPalace daemon is running\n"}}
  end

  test "tests are configured to use the mock, never the real binary" do
    assert Application.fetch_env!(:butler, :cli) == Butler.CLIMock
  end

  test "the mock fails the test when called without an expectation" do
    assert_raise Mox.UnexpectedCallError, fn -> CLI.run(["daemon", "stop"]) end
  end
end
