defmodule Butler.Jobs.OrphansTest do
  use ExUnit.Case, async: true

  alias Butler.Jobs.Job
  alias Butler.Jobs.Orphans

  @moduletag :tmp_dir

  defp proc!(root, pid, cmdline) do
    dir = Path.join(root, Integer.to_string(pid))
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "cmdline"), String.replace(cmdline, " ", <<0>>))
    dir
  end

  defp job(os_pid), do: %Job{id: "j#{os_pid}", kind: "mine", state: :running, os_pid: os_pid}

  test "mempalace_process?/2 matches the command line only", %{tmp_dir: root} do
    proc!(root, 10, "/usr/bin/python /home/u/.local/bin/mempalace --palace /p mine /s --direct")
    proc!(root, 11, "/usr/bin/vim notes.txt")

    assert Orphans.mempalace_process?(10, proc_root: root)
    refute Orphans.mempalace_process?(11, proc_root: root)
    refute Orphans.mempalace_process?(12, proc_root: root)
  end

  test "terminates a live mempalace orphan (TERM) and leaves recycled pids alone", %{
    tmp_dir: root
  } do
    dir = proc!(root, 10, "mempalace --palace /p mine /s --direct")
    proc!(root, 11, "/usr/bin/vim notes.txt")
    parent = self()

    signal = fn pid, name ->
      send(parent, {:signal, pid, name})
      File.rm_rf!(dir)
    end

    jobs = [job(10), job(11), job(12), %Job{id: "no-pid", os_pid: nil}]

    assert Orphans.reap(jobs, proc_root: root, signal: signal, grace_ms: 200) == [10]
    assert_received {:signal, 10, "TERM"}
    refute_received {:signal, _, _}
  end

  test "escalates to KILL when the process ignores TERM", %{tmp_dir: root} do
    dir = proc!(root, 10, "mempalace mine")
    parent = self()

    signal = fn pid, name ->
      send(parent, {:signal, pid, name})
      if name == "KILL", do: File.rm_rf!(dir)
    end

    assert Orphans.reap([job(10)], proc_root: root, signal: signal, grace_ms: 50) == [10]
    assert_received {:signal, 10, "TERM"}
    assert_received {:signal, 10, "KILL"}
  end
end
