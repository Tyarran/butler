defmodule Butler.MCP.ToolsTest do
  use ExUnit.Case, async: true

  alias Butler.MCP.Tools

  @read ~w(
    mempalace_status mempalace_list_wings mempalace_list_rooms mempalace_get_taxonomy
    mempalace_get_aaak_spec mempalace_traverse mempalace_find_tunnels mempalace_graph_stats
    mempalace_list_tunnels mempalace_list_hallways mempalace_follow_tunnels mempalace_search
    mempalace_check_duplicate mempalace_get_drawer mempalace_list_drawers mempalace_diary_read
    mempalace_kg_query mempalace_kg_stats mempalace_kg_timeline
  )

  @write ~w(
    mempalace_add_drawer mempalace_checkpoint mempalace_delete_by_source mempalace_delete_drawer
    mempalace_update_drawer mempalace_diary_write mempalace_kg_add mempalace_kg_invalidate
    mempalace_create_tunnel mempalace_delete_tunnel mempalace_delete_hallway
    mempalace_hook_settings mempalace_memories_filed_away mempalace_kg_supersede
  )

  test "the read allowlist has exactly the 19 READ tools" do
    assert Enum.sort(Tools.read_tools()) == Enum.sort(@read)
    assert length(@read) == 19
    assert Tools.read?("mempalace_search")
    assert Tools.read?("mempalace_kg_timeline")
    refute Tools.read?("mempalace_add_drawer")
  end

  test "the write allowlist is the 13 WRITE_TOOLS plus kg_supersede" do
    assert Enum.sort(Tools.write_tools()) == Enum.sort(@write)
    assert length(@write) == 14
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
