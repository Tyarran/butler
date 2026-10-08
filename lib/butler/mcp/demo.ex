defmodule Butler.MCP.Demo do
  @moduledoc """
  **Synthetic** status of the MCP proxy, for `mix butler.demo`.

  In demo mode no backend process is ever started: the MCP page shows this
  fixed, invented snapshot (fake OS pids, made-up counters) so that Butler
  can be tried or screenshotted without MemPalace.
  """

  @minute 60_000

  @doc "A made-up status of both backends, with timestamps relative to `now_ms`."
  @spec status(integer()) :: [map()]
  def status(now_ms \\ System.system_time(:millisecond)) do
    [
      %{
        id: :full,
        status: :ready,
        active: %{os_pid: 41_207, started_at: now_ms - 3 * @minute},
        standby: %{os_pid: 41_388, started_at: now_ms - 3 * @minute},
        starting: 0,
        failures: 0,
        last_error: nil,
        next_rotation_at: now_ms + 7 * @minute + 12_000,
        idle_rotation_ms: 10 * @minute,
        requests: 128,
        errors: 2,
        rotations: 5,
        sessions: 3
      },
      %{
        id: :light,
        status: :degraded,
        active: %{os_pid: 41_512, started_at: now_ms - 9 * @minute},
        standby: nil,
        starting: 1,
        failures: 0,
        last_error: nil,
        next_rotation_at: now_ms + 55_000,
        idle_rotation_ms: 10 * @minute,
        requests: 4_212,
        errors: 0,
        rotations: 11,
        sessions: 6
      }
    ]
  end
end
