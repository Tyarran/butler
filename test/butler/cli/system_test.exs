defmodule Butler.CLI.SystemTest do
  use ExUnit.Case, async: true

  alias Butler.CLI.System, as: Runner
  alias Butler.Test.QueueFixture

  setup do
    dir = QueueFixture.tmp_dir!()
    {:ok, dir: dir}
  end

  defp script!(dir, body) do
    path = Path.join(dir, "fake-mempalace")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  test "passes arguments as a list, without any shell interpretation", %{dir: dir} do
    bin = script!(dir, ~s|for a in "$@"; do echo "[$a]"; done\n|)
    nasty = ["a b", "$(echo pwned)", "; rm -rf /", "'quoted'", "*"]

    assert {:ok, %{status: 0, output: output}} = Runner.run(nasty, bin: bin)

    assert output ==
             "[a b]\n[$(echo pwned)]\n[; rm -rf /]\n['quoted']\n[*]\n"
  end

  test "returns the exit status and combined stdout/stderr", %{dir: dir} do
    bin = script!(dir, "echo out; echo err >&2; exit 3\n")

    assert {:ok, %{status: 3, output: output}} = Runner.run([], bin: bin)
    assert output =~ "out"
    assert output =~ "err"
  end

  test "streams lines to on_output as they arrive", %{dir: dir} do
    bin = script!(dir, "echo one; sleep 0.3; echo two\n")
    parent = self()

    assert {:ok, %{output: "one\ntwo\n"}} =
             Runner.run([], bin: bin, on_output: &send(parent, {:line, &1}))

    assert_received {:line, "one"}
    assert_received {:line, "two"}
  end

  test "handles a last line without trailing newline", %{dir: dir} do
    bin = script!(dir, "printf 'abc'\n")
    parent = self()

    assert {:ok, %{output: "abc"}} =
             Runner.run([], bin: bin, on_output: &send(parent, {:line, &1}))

    assert_received {:line, "abc"}
  end

  test "kills the process by os_pid on timeout and returns partial output", %{dir: dir} do
    pidfile = Path.join(dir, "pid")
    bin = script!(dir, ~s|echo started\necho $$ > "$1"\nexec sleep 30\n|)

    started = System.monotonic_time(:millisecond)
    assert {:error, {:timeout, partial}} = Runner.run([pidfile], bin: bin, timeout: 400)
    assert System.monotonic_time(:millisecond) - started < 5_000
    assert partial =~ "started"

    pid = pidfile |> File.read!() |> String.trim()
    assert eventually(fn -> not File.dir?("/proc/#{pid}") end), "process #{pid} is still alive"
  end

  test "reports a missing executable" do
    assert {:error, {:executable_not_found, "/nonexistent/mempalace"}} =
             Runner.run(["status"], bin: "/nonexistent/mempalace")

    assert {:error, {:executable_not_found, "definitely-not-a-binary-xyz"}} =
             Runner.run([], bin: "definitely-not-a-binary-xyz")
  end

  test "rejects non-binary arguments and NUL bytes" do
    assert {:error, {:invalid_args, _}} = Runner.run(["ok", 42], bin: "/bin/echo")
    assert {:error, {:invalid_args, _}} = Runner.run(["a\0b"], bin: "/bin/echo")
    assert {:error, {:invalid_args, _}} = Runner.run("daemon status", bin: "/bin/echo")
  end

  defp eventually(fun, attempts \\ 40) do
    cond do
      fun.() -> true
      attempts == 0 -> false
      true -> Process.sleep(50) && eventually(fun, attempts - 1)
    end
  end
end
