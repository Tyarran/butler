defmodule Butler.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias Butler.MCP.Tools

  test "the read allowlist has the 19 READ tools" do
    assert length(Tools.read_tools()) == 19
    assert Tools.read?("mempalace_search")
    assert Tools.read?("mempalace_kg_timeline")
    refute Tools.read?("mempalace_add_drawer")
  end

  test "the write allowlist is the 13 WRITE_TOOLS plus kg_supersede" do
    assert length(Tools.write_tools()) == 14
    assert Tools.write?("mempalace_kg_supersede")
    assert Tools.write?("mempalace_diary_write")
    refute Tools.write?("mempalace_search")
  end

  test "maintenance and unknown tools are in neither list" do
    for name <- ~w(mempalace_mine mempalace_sync mempalace_reconnect mempalace_event_append nope) do
      refute Tools.read?(name)
      refute Tools.write?(name)
    end

    assert Tools.read_tools() -- Tools.write_tools() == Tools.read_tools()
  end
end
