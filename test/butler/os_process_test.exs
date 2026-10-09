defmodule Butler.OSProcessTest do
  # Not async: the integration test changes the OS environment of the VM.
  use ExUnit.Case, async: false

  alias Butler.CLI.System, as: Runner
  alias Butler.MCP.Config
  alias Butler.OSProcess

  @var "MEMPALACE_DAEMON_STATE_ROOT"

  test "port_env/1 converts pairs and always unsets the daemon state root" do
    assert OSProcess.port_env([{"A", "1"}]) == [{~c"A", ~c"1"}, {~c"#{@var}", false}]
    assert OSProcess.port_env(%{}) == [{~c"#{@var}", false}]
  end

  test "MCP backends carry the direct write routing environment" do
    env = Config.env()

    for {name, value} <- OSProcess.routing_env(), do: assert(env[name] == value)
  end

  @tag :tmp_dir
  test "a spawned process does not inherit MEMPALACE_DAEMON_STATE_ROOT", %{tmp_dir: dir} do
    previous = System.get_env(@var)
    System.put_env(@var, "/tmp/synthetic/daemon-root")

    on_exit(fn ->
      if previous, do: System.put_env(@var, previous), else: System.delete_env(@var)
    end)

    bin = Path.join(dir, "fake-mempalace")
    File.write!(bin, "#!/bin/sh\necho \"root=[${#{@var}-unset}]\"\n")
    File.chmod!(bin, 0o755)

    assert {:ok, %{status: 0, output: "root=[unset]\n"}} = Runner.run([], bin: bin)
  end
end
