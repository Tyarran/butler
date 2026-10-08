defmodule Butler.MCP.ConfigTest do
  use ExUnit.Case, async: false

  alias Butler.MCP.Config

  setup do
    previous = Application.fetch_env(:butler, :mcp)
    previous_palace = Application.fetch_env(:butler, :palace_path)

    on_exit(fn ->
      restore(:mcp, previous)
      restore(:palace_path, previous_palace)
    end)

    Application.delete_env(:butler, :mcp)
  end

  defp restore(key, {:ok, value}), do: Application.put_env(:butler, key, value)
  defp restore(key, :error), do: Application.delete_env(:butler, key)

  test "backends/0 lists the full and light backends" do
    assert Config.backends() == [:full, :light]
  end

  test "defaults" do
    assert Config.idle_rotation_ms() == 600_000
    assert Config.max_start_failures() == 3
    assert Config.request_timeout_ms() == 120_000
    assert Config.startup_timeout_ms() == 60_000
    assert Config.session_ttl_ms() == 3_600_000
  end

  test "default binaries are the MemPalace MCP executables" do
    assert Config.bin(:full) == "mempalace-mcp"
    assert Config.bin(:light) == "mempalace-light-mcp"
  end

  test "values come from the :mcp application environment" do
    Application.put_env(:butler, :mcp,
      idle_rotation_ms: 50,
      max_start_failures: 5,
      backends: %{full: [bin: "/tmp/fake-full"], light: [bin: "/tmp/fake-light"]}
    )

    assert Config.idle_rotation_ms() == 50
    assert Config.max_start_failures() == 5
    assert Config.bin(:full) == "/tmp/fake-full"
    assert Config.bin(:light) == "/tmp/fake-light"
  end

  test "env/0 points the backends at the configured palace" do
    Application.put_env(:butler, :palace_path, "/tmp/some/palace")

    assert %{"MEMPALACE_PALACE_PATH" => "/tmp/some/palace", "MEMPALACE_MCP_IDLE_HOURS" => "0"} =
             Config.env()
  end

  test "backend?/1 accepts only the known backends" do
    assert Config.backend?(:full)
    assert Config.backend?(:light)
    refute Config.backend?(:other)
    refute Config.backend?("full")
  end

  test "enabled?/0 follows :start_mcp (off in test)" do
    refute Config.enabled?()
  end
end
