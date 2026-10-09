# Test inventory (phase 0)

> **Historical snapshot.** Phase 7 deleted the tests of `Commands.Guard`,
> `Commands.Direct`, the CLI-based `Commands.Submit`, `Daemon.Status`,
> `Daemon.Control`, `Jobs.Watcher`, `DaemonLive` and the daemon-based
> `DaemonFixture`, and rewrote the `JobsLive`, `JobLive`, `LaunchLive`,
> `MaintenanceLive` and demo tests on Butler's own queue (`test/support/engine.ex`,
> `Butler.Test.Engine`). New: `jobs_test.exs`, `commands/submit_test.exs`,
> `live/worker_live_test.exs`. The tables below describe the state before the
> daemon replacement.

Snapshot of `test/**` before the daemon-replacement work. `n` is the number of
`test "..."` blocks. Mox mock: `Butler.CLIMock` (`Mox.defmock(Butler.CLIMock, for: Butler.CLI)`
in `test/test_helper.exs`, selected through `config :butler, :cli`, see `config/test.exs`).

## Shared test infrastructure

| File | Purpose |
| --- | --- |
| `test/test_helper.exs` | Defines `Butler.CLIMock` for the `Butler.CLI` behaviour and starts ExUnit. |
| `test/support/queue_fixture.ex` | `Butler.Test.QueueFixture`: builds synthetic `queue.sqlite3` files (WAL) with the **exact Python daemon schema** (`jobs` table: `id, kind, payload_json, state, priority, dedupe_key, created_at, started_at, finished_at, result_json, error_json, attempts`; indexes `idx_jobs_state`, `idx_jobs_dedupe`, partial unique `idx_jobs_dedupe_active` on queued/running). `tmp_dir!/0` (auto-removed), `create!/1`, `insert_job!/2` (map or JSON-string columns, to test malformed JSON), `iso_ago/1` (`+00:00` timestamps like the daemon). Opened through Exqlite, **write-capable**: only used by tests. |
| `test/support/daemon_fixture.ex` | `Butler.Test.DaemonFixture`: fake MemPalace home `<tmp>/daemon/<palace_key>/` with an empty queue and optional `endpoint.json` (`running: true` uses the test VM pid, `:stale` a dead pid, `queue: false`). Sets `:butler` env (`palace_path`, `mempalace_home`) and restores it on exit (so tests using it are `async: false`). Synthetic palace `/tmp/synthetic/palace`. Never writes a `token`. |
| `test/support/fake_mcp.sh` | **Fake MCP stdio backend**: bash, line-delimited JSON-RPC, synthetic data. First arg = startup mode (`never_start`, `exit_on_start`, `exit_unless_file <path>`, default healthy); the request `method` selects behaviour (`crash`, `hang`, `slow` 0.4 s concurrent, `noisy` non-JSON line, `big` ~200 KB, else echoes `{pid, method}`; answers `initialize`, ignores `notifications/*`). Replaces the real `mempalace-mcp`/`mempalace-light-mcp` in all MCP tests. |
| `test/support/conn_case.ex` | `ButlerWeb.ConnCase`: Phoenix `ConnTest`/`LiveViewTest` case template (no DB). |

## Unit and integration tests (`test/butler/**`)

| File | n | Purpose |
| --- | --- | --- |
| `cli_test.exs` | 3 | `Butler.CLI` behaviour dispatch to the configured implementation (Mox). |
| `cli/system_test.exs` | 7 | `Butler.CLI.System` real implementation: argument list (no shell), timeout, kill by `os_pid`, using harmless local programs. |
| `commands/args_test.exs` | 16 | `Butler.Commands.Args`: argument-list builders for mine/sweep/sync/..., `--dry-run` forced for sync, mode/extract whitelists. |
| `commands/input_test.exs` | 15 | `Butler.Commands.Input`: form param validation (absolute existing paths, positive ints, no leading `-`, `sync` ignores apply-like params). |
| `commands/guard_test.exs` | 10 | `Butler.Commands.Guard`: direct-command guard (refuse when a daemon job is active, uses queue + daemon fixtures). |
| `commands/direct_test.exs` | 18 | `Butler.Commands.Direct`: orchestrates direct maintenance commands (Mox CLI, daemon stop/start flow). |
| `commands/submit_test.exs` | 17 | `Butler.Commands.Submit`: job submission through the CLI (`--background`), result parsing (Mox + fixtures). |
| `daemon/locator_test.exs` | 10 | `Butler.Daemon.Locator`: finds state dir via `endpoint.json`, latest `started_at`, fallback on `palace_key`, never reads `token`. |
| `daemon/status_test.exs` | 6 | `Butler.Daemon.Status`: running/stopped/stale from endpoint + pid liveness + queue. |
| `daemon/control_test.exs` | 11 | `Butler.Daemon.Control`: daemon start/stop through the CLI (Mox). |
| `jobs/job_test.exs` | 12 | `Butler.Jobs.Job`: row to struct (states, JSON decoding, durations). |
| `jobs/store_test.exs` | 18 | `Butler.Jobs.Store`: **read-only** access to `queue.sqlite3`, filters, history, malformed JSON. |
| `jobs/counts_test.exs` | 4 | `Butler.Jobs` per-state counters. |
| `jobs/duration_hint_test.exs` | 9 | `Butler.Jobs.DurationHint`: median of >= 3 succeeded jobs of the same kind, running hint. |
| `jobs/watcher_test.exs` | 5 | `Butler.Jobs.Watcher`: polling GenServer broadcasting `{:queue_changed, snapshot}` over PubSub. |
| `mcp_test.exs` | 12 | `Butler.MCP` facade/supervision with the fake backend. |
| `mcp/backend_test.exs` | 14 | `Butler.MCP.Backend` start/stop, request routing, fake MCP + queue fixture. |
| `mcp/worker_test.exs` | 17 | `Butler.MCP.Worker`: long-lived backend process, restart, timeouts, crash/hang/noisy/big, kill by `os_pid`. |
| `mcp/protocol_test.exs` | 13 | `Butler.MCP.Protocol`: JSON-RPC classification, framing, error constructors. |
| `mcp/sessions_test.exs` | 6 | `Butler.MCP.Sessions`: HTTP session bookkeeping. |
| `mcp/config_test.exs` | 7 | `Butler.MCP.Config`: `BUTLER_MCP_*` env/binary configuration. |
| `palace_test.exs` | 7 | `Butler.Palace`: palace path, home, binary configuration. |
| `demo_test.exs` | 12 | `Butler.Demo`: builds the synthetic demo home and queue; `Butler.CLI.Demo` runs no program. |
| `test_support/queue_fixture_test.exs` | 5 | Tests the fixture itself (schema parity, helpers). |

## Web tests (`test/butler_web/**`)

| File | n | Purpose |
| --- | --- | --- |
| `components/ui_components_test.exs` | 6 | Function components (badges, cards, ...). |
| `controllers/error_html_test.exs`, `error_json_test.exs` | 2 + 2 | Error renderers (Phoenix default). |
| `controllers/mcp_controller_test.exs` | 24 | MCP proxy routes `/mcp/full`, `/mcp/light`: loopback only, `Origin`/`Host` validation, JSON-RPC over HTTP against the fake backend. |
| `format_test.exs` | 4 | `ButlerWeb.Format` helpers (durations, timestamps). |
| `live/daemon_live_test.exs` | 8 | Daemon status page. |
| `live/daemon_control_live_test.exs` | 10 | Daemon start/stop buttons (Mox CLI). |
| `live/jobs_live_test.exs` | 9 | Job list (stream, counters, live updates). |
| `live/jobs_filter_live_test.exs` | 12 | Job list filters. |
| `live/job_live_test.exs` | 11 | Job detail page (payload, error, stdout block). |
| `live/launch_live_test.exs` | 12 | Job submission forms (mine/sweep/sync), validation (Mox). |
| `live/maintenance_live_test.exs` | 8 | Direct maintenance commands page (Mox). |
| `live/mcp_live_test.exs` | 7 | MCP proxy status page (fake backend). |
| `live/palace_live_test.exs` | 2 | Palace placeholder page. |

## Conventions seen in the existing tests

* Safety invariants are encoded as tests (no token read, read-only store, arg-list
  CLI, forced `--dry-run`).
* Tests that touch global app env use `DaemonFixture` and are `async: false`;
  pure ones are `async: true`.
* No test starts a real MemPalace binary; the CLI is `Butler.CLIMock` and MCP
  backends are `test/support/fake_mcp.sh`.
* The current queue fixture is **write-capable only for tests**; the production
  `Store` is read-only. Phase 1 will need a writable store (a deliberate break of
  safety rule 3 for Butler's **own** queue DB, not the Python daemon's), so these
  tests and rule 3 in `AGENTS.md` / `CONTRIBUTING.md` must be revisited.

## Modules not previously read

| Module | Summary |
| --- | --- |
| `lib/butler/daemon/locator.ex` | `Butler.Daemon.Locator`: `find/2` scans `<root>/*/endpoint.json` for the wanted `palace_path` (only `endpoint.json` is read, never `token`), picks the latest `started_at`, else falls back to the directory named `palace_key/1` (first 24 hex of SHA-256 of the normalized path). Returns `%Locator{dir, queue_path, pid, palace_path, started_at, host, port}`. |
| `lib/butler/jobs/duration_hint.ex` | `Butler.Jobs.DurationHint`: `typical_seconds/2` (median of succeeded jobs of a kind, `nil` below 3 samples), `hint/3` renders `"running for N min, usual duration ~M min"` for running jobs. Pure. |
| `lib/butler/commands/input.ex` | `Butler.Commands.Input`: `mine/1`, `sweep/1`, `sync/1` validate string form params into `Args` maps, `{:ok, map} / {:error, %{field => message}}`. Paths absolute and existing, enums whitelisted, positive integers, text not starting with `-`/containing NUL. `sync` takes only `wing` and `roots` (no way to express `--apply`). No Ecto. |
| `ButlerWeb.Layouts` (`lib/butler_web/components/layouts.ex`) | `app/1` shell (`flash`, `active`, `title` attrs) with a nav (`@nav_items`: Daemon, ... ; `nav_items/0`), `flash_group/1`, `theme_toggle/1`, embeds `layouts/*` (root template). All LiveViews wrap in `<Layouts.app flash={@flash} active={...} title=...>`. |
| `ButlerWeb.JobLive` (`lib/butler_web/live/job_live.ex`) | Job detail page: mounts by `id`, subscribes to `Watcher` (`{:queue_changed, _}` reloads via `Store`), pretty-prints payload/error/result, renders `stdout` in a terminal block. Read-only. |
| `ButlerWeb.PalaceLive` (`lib/butler_web/live/palace_live.ex`) | 27-line placeholder ("not part of v1"), assigns `page_title`, renders inside `Layouts.app active={:palace}`. |
| `mix butler.demo` (`lib/mix/tasks/butler.demo.ex`) | `mix butler.demo [--dir DIR] [--port PORT] [--build-only]`: builds a synthetic home (`BUTLER_MEMPALACE_HOME` fixture dir, fake palace, queue with a job in every state via `Butler.Demo`) and starts the endpoint with `Butler.CLI.Demo` instead of the real CLI. Used by `mise run screenshots`. |
