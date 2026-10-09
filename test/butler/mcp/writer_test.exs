defmodule Butler.MCP.WriterTest do
  use ExUnit.Case, async: true

  alias Butler.MCP.Writer

  @moduletag :tmp_dir
  @fake Path.expand("../../support/fake_mcp.sh", __DIR__)

  defp start_writer(tmp, opts \\ []) do
    log = Path.join(tmp, "calls.log")
    env = %{"FAKE_MCP_CALL_LOG" => log}
    name = :"writer_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: name, bin: @fake, env: env, startup_timeout_ms: 5_000], opts)
    start_supervised!({Writer, opts})
    {name, log}
  end

  defp result_text(%{"result" => %{"content" => [%{"text" => text}]}}), do: text

  test "starts lazily and is never stopped on its own", %{tmp_dir: tmp} do
    {w, _log} = start_writer(tmp)
    assert Writer.os_pid(w) == nil

    assert {:ok, answer} = Writer.call_tool(w, "fake_ok", %{})
    assert result_text(answer) =~ "drawer_id"
    pid = Writer.os_pid(w)
    assert is_integer(pid)

    assert {:ok, _} = Writer.call_tool(w, "fake_ok", %{})
    assert Writer.os_pid(w) == pid
  end

  test "runs with MEMPALACE_MCP_IDLE_HOURS=0", %{tmp_dir: tmp} do
    {w, _log} = start_writer(tmp)
    {:ok, answer} = Writer.call_tool(w, "fake_env", %{})
    assert result_text(answer) =~ ~s("idle_hours":"0")
  end

  test "stop kills the process and the next call restarts it cold", %{tmp_dir: tmp} do
    {w, _log} = start_writer(tmp)
    {:ok, _} = Writer.call_tool(w, "fake_ok", %{})
    old = Writer.os_pid(w)

    assert :ok = Writer.stop(w)
    assert Writer.os_pid(w) == nil
    refute File.exists?("/proc/#{old}")
    assert :ok = Writer.stop(w)

    {:ok, _} = Writer.call_tool(w, "fake_ok", %{})
    assert Writer.os_pid(w) not in [nil, old]
  end

  test "stop without a writer process is a no-op" do
    assert :ok = Writer.stop(:no_such_writer)
  end

  test "stop returns only once a TERM-ignoring process is really gone", %{tmp_dir: tmp} do
    {w, _log} = start_writer(tmp, args: ["ignore_term"])
    {:ok, _} = Writer.call_tool(w, "fake_ok", %{})
    old = Writer.os_pid(w)

    assert :ok = Writer.stop(w)
    refute File.exists?("/proc/#{old}")
  end

  test "a stop that times out is an error, not :ok" do
    silent = spawn_link(fn -> Process.sleep(:infinity) end)
    assert {:error, :stop_timeout} = Writer.stop(silent, 50)
  end

  test "a timeout kills the writer and is not retried", %{tmp_dir: tmp} do
    {w, log} = start_writer(tmp)
    {:ok, _} = Writer.call_tool(w, "fake_ok", %{})
    old = Writer.os_pid(w)

    assert {:error, :timeout} = Writer.call_tool(w, "fake_hang", %{}, timeout_ms: 200)
    assert Writer.os_pid(w) == nil
    refute File.exists?("/proc/#{old}")
    assert File.read!(log) |> String.split("\n", trim: true) == ["fake_ok", "fake_hang"]
  end

  test "reports a missing executable", %{tmp_dir: tmp} do
    {w, _log} = start_writer(tmp, bin: "/nonexistent/butler-test/nope")

    assert {:error, {:start_failed, {:executable_not_found, _}}} =
             Writer.call_tool(w, "fake_ok", %{})
  end

  test "on_start receives the os pid", %{tmp_dir: tmp} do
    {w, _log} = start_writer(tmp)
    test = self()
    {:ok, _} = Writer.call_tool(w, "fake_ok", %{}, on_start: &send(test, {:started, &1}))
    assert_receive {:started, pid} when is_integer(pid)
    assert pid == Writer.os_pid(w)
  end
end
