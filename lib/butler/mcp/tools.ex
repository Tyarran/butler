defmodule Butler.MCP.Tools do
  @moduledoc """
  Allowlists of MemPalace MCP tools (names as of MemPalace 3.10.0, see
  `docs/spikes.md`, Q4).

    * `read_tools/0` - the 19 tools the MCP proxy may forward (decision 11);
    * `write_tools/0` - the tools a queued `mcp_tool` job may call (decision
      12): the 13 `WRITE_TOOLS` of MemPalace plus `mempalace_kg_supersede`,
      which MemPalace leaves unclassified.

  Both lists are explicit on purpose: they are never derived from MemPalace's
  own classification. Maintenance tools (`mempalace_mine`, `mempalace_sync`,
  `mempalace_reconnect`) and anything unknown are in neither list.
  """

  @read_tools ~w(
    mempalace_status mempalace_list_wings mempalace_list_rooms mempalace_get_taxonomy
    mempalace_get_aaak_spec mempalace_traverse mempalace_find_tunnels mempalace_graph_stats
    mempalace_list_tunnels mempalace_list_hallways mempalace_follow_tunnels mempalace_search
    mempalace_check_duplicate mempalace_get_drawer mempalace_list_drawers mempalace_diary_read
    mempalace_kg_query mempalace_kg_stats mempalace_kg_timeline
  )

  @write_tools ~w(
    mempalace_add_drawer mempalace_checkpoint mempalace_delete_by_source mempalace_delete_drawer
    mempalace_update_drawer mempalace_diary_write mempalace_kg_add mempalace_kg_invalidate
    mempalace_create_tunnel mempalace_delete_tunnel mempalace_delete_hallway
    mempalace_hook_settings mempalace_memories_filed_away mempalace_kg_supersede
  )

  @doc "Tools the proxy forwards (read-only, no writer lease)."
  @spec read_tools() :: [String.t()]
  def read_tools, do: @read_tools

  @doc "Tools a queued `mcp_tool` job may call."
  @spec write_tools() :: [String.t()]
  def write_tools, do: @write_tools

  @doc "Whether the proxy may forward a call to `name`."
  @spec read?(term()) :: boolean()
  def read?(name), do: name in @read_tools

  @doc "Whether a queued `mcp_tool` job may call `name`."
  @spec write?(term()) :: boolean()
  def write?(name), do: name in @write_tools
end
