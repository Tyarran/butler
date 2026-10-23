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
        workers:
          for {os_pid, pending} <- [{41_207, 1}, {41_388, 0}, {41_391, 0}, {41_402, 2}] do
            worker(os_pid, :ready, now_ms - 3 * @minute, pending)
          end,
        pool_size: 4,
        ready: 4,
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
        workers: [
          worker(41_512, :ready, now_ms - 9 * @minute, 0),
          worker(41_518, :ready, now_ms - 9 * @minute, 1),
          worker(41_533, :ready, now_ms - 9 * @minute, 0),
          worker(nil, :starting, now_ms - 2_000, 0)
        ],
        pool_size: 4,
        ready: 3,
        starting: 1,
        failures: 0,
        last_error: nil,
        next_rotation_at: nil,
        idle_rotation_ms: 0,
        requests: 4_212,
        errors: 0,
        rotations: 11,
        sessions: 6
      }
    ]
  end

  defp worker(os_pid, phase, started_at, pending) do
    %{os_pid: os_pid, phase: phase, started_at: started_at, pending: pending}
  end
end
