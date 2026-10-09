defmodule Butler.Daemon.LegacyTest do
  use ExUnit.Case, async: true

  alias Butler.Daemon.Legacy

  @palace "/tmp/synthetic/palace"

  setup %{tmp_dir: tmp} do
    proc = Path.join(tmp, "proc")
    File.mkdir_p!(Path.join(proc, "4321"))
    {:ok, root: Path.join(tmp, "daemon"), proc: proc}
  end

  defp write_endpoint!(root, pid) do
    dir = Path.join(root, "abc")
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "endpoint.json"),
      Jason.encode!(%{"pid" => pid, "palace_path" => @palace})
    )
  end

  defp running?(root, proc),
    do: Legacy.running?(root: root, palace_path: @palace, proc_root: proc)

  @tag :tmp_dir
  test "true when the endpoint PID is alive", %{root: root, proc: proc} do
    write_endpoint!(root, 4321)
    assert running?(root, proc)
  end

  @tag :tmp_dir
  test "false when the PID is dead", %{root: root, proc: proc} do
    write_endpoint!(root, 9999)
    refute running?(root, proc)
  end

  @tag :tmp_dir
  test "false when there is no daemon directory", %{root: root, proc: proc} do
    refute running?(root, proc)
  end

  @tag :tmp_dir
  test "never reads the token file", %{root: root, proc: proc} do
    write_endpoint!(root, 4321)
    token = Path.join([root, "abc", "token"])
    File.write!(token, "synthetic")
    File.chmod!(token, 0o000)

    assert running?(root, proc)
  end
end
