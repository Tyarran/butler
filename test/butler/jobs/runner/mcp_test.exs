defmodule Butler.Jobs.Runner.MCPTest do
  use ExUnit.Case, async: true

  alias Butler.Jobs.Job
  alias Butler.Jobs.Runner.MCP
  alias Butler.MCP.Writer

  @moduletag :tmp_dir
  @fake Path.expand("../../../support/fake_mcp.sh", __DIR__)

  defp job(kind, payload), do: %Job{id: "j1", kind: kind, payload: payload}

  defp start_writer(tmp) do
    name = :"writer_#{System.unique_integer([:positive])}"
    log = Path.join(tmp, "calls.log")

    start_supervised!(
      {Writer,
       name: name, bin: @fake, env: %{"FAKE_MCP_CALL_LOG" => log}, startup_timeout_ms: 5_000}
    )

    {name, log}
  end

  defp calls(log), do: log |> File.read!() |> String.split("\n", trim: true)

  describe "request/2" do
    test "diary_write maps to mempalace_diary_write with topic defaulting to general" do
      assert {:ok, "mempalace_diary_write",
              %{"agent_name" => "a", "entry" => "e", "topic" => "general"} = args} =
               MCP.request("diary_write", %{"agent_name" => "a", "entry" => "e"})

      refute Map.has_key?(args, "wing")

      assert {:ok, _, %{"topic" => "t", "wing" => "w"}} =
               MCP.request("diary_write", %{
                 "agent_name" => "a",
                 "entry" => "e",
                 "topic" => "t",
                 "wing" => "w"
               })
    end

    test "diary_write validates its payload" do
      assert {:error, _} = MCP.request("diary_write", %{"agent_name" => "a"})
      assert {:error, _} = MCP.request("diary_write", %{"agent_name" => "a", "entry" => ""})

      assert {:error, _} =
               MCP.request("diary_write", %{"agent_name" => "a", "entry" => "e", "x" => 1})
    end

    test "mcp_tool only accepts the write allowlist" do
      assert {:ok, "mempalace_kg_supersede", %{"a" => 1}} =
               MCP.request("mcp_tool", %{
                 "name" => "mempalace_kg_supersede",
                 "arguments" => %{"a" => 1}
               })

      assert {:ok, "mempalace_add_drawer", %{}} =
               MCP.request("mcp_tool", %{"name" => "mempalace_add_drawer"})

      for name <- ~w(mempalace_search mempalace_mine mempalace_sync mempalace_reconnect nope) do
        assert {:error, _} = MCP.request("mcp_tool", %{"name" => name})
      end

      assert {:error, _} =
               MCP.request("mcp_tool", %{"name" => "mempalace_add_drawer", "arguments" => []})

      assert {:error, _} = MCP.request("mcp_tool", %{"name" => "mempalace_add_drawer", "x" => 1})
    end
  end

  describe "run/2" do
    test "success", %{tmp_dir: tmp} do
      {w, _} = start_writer(tmp)

      assert {:ok, %{tool: "mempalace_diary_write", result: %{"success" => true}}} =
               MCP.run(job("diary_write", %{"agent_name" => "a", "entry" => "e"}), writer: w)
    end

    test "an invalid payload never reaches the writer", %{tmp_dir: tmp} do
      {w, log} = start_writer(tmp)

      assert {:error, %{class: "InvalidPayload"}} =
               MCP.run(job("mcp_tool", %{"name" => "mempalace_search"}), writer: w)

      refute File.exists?(log)
      assert Writer.os_pid(w) == nil
    end

    test "failures: success false, error key, isError, JSON-RPC error", %{tmp_dir: tmp} do
      {w, log} = start_writer(tmp)

      for {tool, class} <- [
            {"fake_success_false", "MCPToolFailed"},
            {"fake_error_key", "MCPToolFailed"},
            {"fake_is_error", "MCPToolFailed"},
            {"fake_rpc_error", "MCPError"}
          ] do
        assert {:error, %{class: ^class}} = run_tool(w, tool)
      end

      assert {:error, %{message: "nope"}} = run_tool(w, "fake_success_false")
      # No retry: one call per run.
      assert length(calls(log)) == 5
    end

    test "lock refusals", %{tmp_dir: tmp} do
      {w, _} = start_writer(tmp)
      assert {:lock_refused, "Peer MCP writer active"} = run_tool(w, "fake_lock")
      assert {:lock_refused, text} = run_tool(w, "fake_lock_text")
      assert text =~ "is held by"
    end

    test "a successful result mentioning the refusal phrase stays succeeded, run once",
         %{tmp_dir: tmp} do
      {w, log} = start_writer(tmp)
      assert {:ok, %{result: %{"success" => true}}} = run_tool(w, "fake_lock_text_ok")
      assert calls(log) == ["fake_lock_text_ok"]
    end

    test "an error key set to null is not a failure", %{tmp_dir: tmp} do
      {w, _} = start_writer(tmp)
      assert {:ok, %{result: %{"error" => nil}}} = run_tool(w, "fake_error_null")
    end

    test "a huge result is truncated before being stored", %{tmp_dir: tmp} do
      {w, _} = start_writer(tmp)

      assert {:ok, %{result: %{"truncated" => true, "text_tail" => tail}}} =
               run_tool(w, "fake_big")

      assert byte_size(tail) <= 65_536
    end

    test "a timeout kills the writer and fails the job", %{tmp_dir: tmp} do
      {w, log} = start_writer(tmp)
      assert {:error, %{class: "Timeout"}} = run_tool(w, "fake_hang", timeout_ms: 200)
      assert Writer.os_pid(w) == nil
      assert calls(log) == ["fake_hang"]
    end
  end

  defp run_tool(writer, tool, opts \\ []) do
    MCP.run(
      job("mcp_tool", %{"name" => tool}),
      [writer: writer, write_tools: [tool]] ++ Keyword.take(opts, [:timeout_ms])
    )
  end
end
