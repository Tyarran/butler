# Plan: Butler replaces the MemPalace Python daemon

Source of truth for the implementation phases. Read `AGENTS.md`, `CONTRIBUTING.md`,
`docs/spikes.md` and `docs/test-inventory.md` first.

## Goal

Butler owns a SQLite job queue plus one serial worker. It executes every job kind
(ephemeral CLI processes and a persistent full MCP writer), exposes a
token-protected asynchronous HTTP API for pi-palace, and gates the MCP proxy during
maintenance. The Python daemon is no longer used (hard cut, no history import).

Everything (code, docs, UI) is in English. Commits are single-line Conventional
Commits in English, made with `jj` only. The repo must be green (`mix precommit`)
at every commit. Edit code with the edit/write tools only.

## Final decisions (not to be re-litigated)

1. **Queue**: Butler-owned SQLite (`exqlite` directly, no Ecto), schema inspired by
   MemPalace `jobs` table. One `Queue` GenServer owns the connection.
2. **One worker, strictly serial.** Claim order: `priority DESC, created_at ASC, rowid`.
3. **All kinds go through the queue**: `mine`, `sweep`, `sync` (apply allowed, default
   dry-run over HTTP), `diary_write`, `mcp_tool` (write allowlist), `repair`,
   `compress`, `migrate-wings`.
4. **Execution**: CLI kinds = ephemeral `mempalace` process through `Butler.CLI`
   (argv list, timeout, kill by `os_pid`), always with `--direct` where the command
   has routing flags, and env `MEMPALACE_CLI_WRITE_ROUTING=direct`,
   `MEMPALACE_WRITE_ROUTING=direct`, `MEMPALACE_HUB_FORWARD=0`. Write MCP kinds =
   persistent full `mempalace-mcp` (`MCP.Writer`), env `MEMPALACE_MCP_IDLE_HOURS=0`.
   All spawned processes share the same `HOME` and config dir (the flock lives under
   `$HOME/.mempalace/locks`).
5. **Writer lifecycle (from spike Q1)**: a full `mempalace-mcp` keeps the palace
   flock after its first write until it exits. So the writer is started lazily on
   the first write job, NEVER stopped on idle, and ALWAYS stopped before every CLI
   job (and before maintenance). The next write restarts it cold. Proxy read
   workers never write, so they do not hold the lock.
6. **Failure policy = MemPalace**: no retry inside the worker loop. Only
   `recover_running` re-queues (max 3 attempts), idempotent kinds only (`mine`,
   `sweep`, `sync`); `diary_write`, `mcp_tool`, `repair`, `compress`,
   `migrate-wings` crashed while running become `failed`.
7. **Graceful shutdown**: kill the child by `os_pid`; idempotent job is put back in
   `queued` with the attempt refunded; non-idempotent job becomes `failed`
   ("interrupted by shutdown").
8. **Orphan protection (v1, in phase 3)**: persist `os_pid`; at startup, if a
   `running` job has a live `os_pid` whose cmdline matches `mempalace`, kill it
   before `recover_running`.
9. **Lock refusal** (spike Q2): detect by regexp on stdout+stderr when exit != 0:
   `palace .+ is held by .+; wait for it to finish or stop the holder before retrying|MineAlreadyRunning`.
   Exit codes and streams are inconsistent, so never rely on them. Butler defines its
   own `error_class` `LockHeldByOtherProcess`. Lock-refused job: back to `queued`,
   attempt refunded, in-memory cooldown (default 60 s, `BUTLER_LOCK_BACKOFF_SECONDS`,
   invalid or <= 0 falls back to default).
10. **API** (`/api/v1`, only client pi-palace): async fire-and-forget, Bearer token
    generated and owned by Butler, plus loopback + Host + Origin validation. Allowed
    kinds over HTTP: `mine`, `sweep`, `sync`, `diary_write`, `mcp_tool`.
    `repair`, `compress`, `migrate-wings` are UI-only: HTTP answers
    `403 kind_not_allowed`. The server always uses its own palace path; a client
    `palace_path` is refused.
11. **MCP proxy reads**: allowlist of the 19 READ tools only; everything else
    (write, maintenance, unknown) is refused with "write tools must be submitted
    through the Butler API". The allowlist lives in `Butler.MCP.Tools`.
12. **Write allowlist for `mcp_tool`**: the 13 `WRITE_TOOLS` plus
    `mempalace_kg_supersede` (see `docs/spikes.md` for the exact names).
13. **Maintenance mode**: for `repair`, `compress`, `migrate-wings` (dry-runs
    included) the proxy answers every request immediately with JSON-RPC error
    `-32001` "Maintenance in progress, retry later"; Butler's MCP workers and the
    writer are stopped for the duration and resumed afterwards (always, in an
    `after`). Reads stay allowed during `mine` and `sweep`.
14. **State dir**: `BUTLER_STATE_DIR`, default `$XDG_STATE_HOME/butler`, else
    `~/.local/state/butler`; dir mode 700; `queue.sqlite3`, `-wal`, `-shm` and
    `token` mode 600. Never the Python daemon dir.
15. **Retention**: terminal jobs (and their verbatim payloads) pruned after 7 days
    (`BUTLER_RETENTION_DAYS`), at startup then daily. No early payload redaction.
16. **CLI output**: `Butler.CLI.System` must not accumulate unbounded output; keep
    only a tail (`max_output_bytes`, default 64 KB) and expose `on_start(os_pid)`
    and `on_output` callbacks.
17. **Out of scope**: Butler availability/supervision (systemd...), MemCastle,
    migration from the Python daemon, pi-palace changes (only document the API
    contract in `docs/api.md`).

## Safety rules (rewrite of AGENTS.md rules 1-4, 6, 7; rule 5 stays)

- Butler reads/writes only its OWN token and queue DB. It never reads
  `~/.mempalace/daemon/**` (token, queue) and never calls the Python daemon.
- Butler has no HTTP client. It serves HTTP only.
- Process spawning only through `Butler.CLI` (argv lists, timeouts, kill by
  `os_pid`) and `Butler.MCP.Worker` (proxy backends and `MCP.Writer`).
- Every routine CLI write carries `--direct`, never `--daemon`/`--background`.
- Tests never run repair/compress/migrate-wings/sync --apply against a real palace;
  they use Mox, the fake MCP backend in `test/support`, throwaway `--palace` and
  state dirs (`BUTLER_STATE_DIR` per test tmp dir, never a real location).
- Tests use synthetic data only; no real diary / `mcp_tool` content.

## Target architecture

```text
ButlerWeb  (LiveViews, JobController, HealthController, Plugs.LoopbackGuard, Plugs.APIAuth)
Butler.Commands     Input (form validation), Submit (validate -> Jobs.enqueue)
Butler.Jobs.Worker  serial GenServer; Jobs.Runner.{CLI,MCP}; Jobs.Kinds (argv + payload validation)
Butler.MCP          proxy + MCP.Writer + MCP.Tools (read allowlist / write allowlist)
Butler.Jobs         Job, Store (SQL), Queue (GenServer owning the connection, PubSub)
Butler.Maintenance  ETS flag read by MCP, written by the worker
Butler.CLI / OSProcess / Palace / Token / Paths
```

Application children: Telemetry, DNSCluster, PubSub, TaskSupervisor,
`Maintenance`, `MCP.Writer`, `MCP.Supervisor` (if enabled), `Jobs.Supervisor`
(rest_for_one: Queue then Worker, Worker shutdown 20_000), Endpoint. Dependencies
only point downward. The engine stays dormant behind a temporary `:start_queue`
flag until phase 7 so that no two writers run during development.

### Data model

```sql
PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA user_version=1;
CREATE TABLE IF NOT EXISTS jobs (
  id TEXT PRIMARY KEY, kind TEXT NOT NULL, payload_json TEXT NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('queued','running','succeeded','failed','cancelled')),
  priority INTEGER NOT NULL DEFAULT 0, dedupe_key TEXT,
  created_at TEXT NOT NULL, started_at TEXT, finished_at TEXT,
  result_json TEXT, error_json TEXT, attempts INTEGER NOT NULL DEFAULT 0, os_pid INTEGER);
CREATE INDEX IF NOT EXISTS idx_jobs_state ON jobs(state, priority);
CREATE UNIQUE INDEX IF NOT EXISTS idx_jobs_dedupe_active ON jobs(dedupe_key)
  WHERE dedupe_key IS NOT NULL AND state IN ('queued','running');
```

Queue operations (SQL in `Jobs.Store`, API in `Jobs.Queue`, `{:ok, _}` tuples,
PubSub broadcasts): `enqueue` (returns `:created | :deduplicated`), `claim_next
(exclude_ids)` in `BEGIN IMMEDIATE` (increments attempts, clears error), `set_os_pid`,
`finish` (guarded `AND state='running'`), `defer(id, claimed_started_at, error)`
(back to queued, attempt refunded, guarded), `cancel` (queued: direct; running:
worker handles), `recover_running(idempotent_kinds, max_attempts: 3)`,
`prune_terminal(days)`, `get`, `list`, `counts`, `kinds`. Refuse to open when
`user_version` is newer than known.

PubSub topics: `butler:queue` `{:job_changed, job}`, `butler:job:<id>`
`{:job_output, id, line}`, `butler:worker` `{:worker_changed, status}` and
`{:maintenance_changed, state}`.

### Worker state machine

Boot: kill orphans -> `recover_running` -> `prune_terminal` -> legacy guard (stay
`:blocked` while the Python daemon is alive, via `Daemon.Legacy.running?/0`: PID
alive only, no token read, no HTTP) -> `:idle`. Idle wakes on `:wake` casts and on
the earliest cooldown expiry (no polling). Running: `Task.Supervisor.async_nolink`
runs the runner; outcomes `{:ok, result}`, `{:error, error}`, `{:lock_refused,
msg}`. Cancel running CLI job: TERM then KILL after a grace period, finish
`cancelled`. Timeouts per kind (defaults: mine/repair/compress/migrate-wings 6 h,
sweep 2 h, sync 1 h; configurable; never infinite). `terminate/2` implements
decision 7.

## HTTP API contract (`docs/api.md` to write in phase 6)

`Authorization: Bearer <token>`, `Plug.Crypto.secure_compare`. Token file created
with mode 600 (create, chmod, then write), 32 random bytes url-base64. `Plug.Parsers`
gets `length: 1_000_000`.

- `POST /api/v1/jobs` body `{kind, payload, dedupe_key?, priority?}` -> `202
  {job: {id, kind, state, dedupe_key, created_at, deduplicated}}` (a dedupe hit also
  returns 202 with the existing job, `deduplicated: true`).
- `GET /api/v1/jobs/:id` -> job without payload unless `?include_payload=true`.
- `GET /api/v1/health` -> `{ok, worker: idle|running|blocked, active_job_id,
  maintenance, counts}`.

Payloads (validated in `Jobs.Kinds`: absolute paths, text not starting with `-`, no
NUL, positive integers, whitelisted enums, unknown keys refused):
`mine {source, mode, wing, agent, dry_run, limit, no_gitignore, include_ignored[],
extract, max_chunks_per_file, redetect_origin}`; `sweep {target}`; `sync {wing?,
roots[]?, dry_run}` with `dry_run` defaulting to true (`--apply` only on an explicit
`false`); `diary_write {agent_name, entry, topic?, wing?}`; `mcp_tool {name,
arguments}` (name in the write allowlist). Errors `{error: {code, message,
field?}}`: 400 `invalid_payload`, 401 `unauthorized`, 403 `forbidden` /
`kind_not_allowed`, 404 `not_found`, 413 `too_large`, 422 `unknown_kind`, 503
`queue_unavailable`. `dedupe_key`: string <= 200 chars.

## Phases (each shippable, green, committed separately)

- **Phase 0 - DONE** (`docs/spikes.md`, `docs/test-inventory.md`).
- **Phase 1 - State dir, token, store.** `Butler.Paths`, `Butler.Token`, read-write
  `Jobs.Store` with schema, modes 700/600, `Daemon.Legacy.running?/0` (reduce
  Locator/Status), tests (`@tag :tmp_dir`): schema, `user_version` refusal, file
  modes, token, SQL cases (enqueue/claim/finish/defer/recover/prune). Rewrite the
  matching AGENTS.md/CONTRIBUTING.md rules in the same commit.
  Commit: `feat(jobs): add read-write queue store in Butler state dir`.
- **Phase 2 - Queue server + PubSub.** `Jobs.Queue`, `Jobs.Supervisor`. Tests:
  serialization, dedupe (incl. unique-index race), cancel queued, PubSub events.
  Commit: `feat(jobs): add queue server with pubsub events`.
- **Phase 3 - DONE.** Kinds, CLI extensions, worker for CLI jobs, orphan reaping.**
  `git mv`-style move of `commands/args.ex` to `jobs/kinds.ex` (use `jj mv`),
  extend it (`--direct`, env vars, sync apply, maintenance argv); extend
  `Butler.CLI`/`CLI.System` with `:on_start`, `:on_output`, `:max_output_bytes`;
  `Jobs.Worker` + `Runner.CLI` (recover, defer/cooldown, cancel, timeout,
  terminate, orphan kill). Mox tests: ordering, one at a time, non-zero exit,
  timeout, lock refusal with refund, cancel with `os_pid` kill, `recover_running`
  matrix, graceful shutdown rules, every mine/sweep/sync argv has `--direct` and no
  `--daemon`. Commit: `feat(jobs): add serial worker for CLI job kinds`.
- **Phase 4 - MCP writer and write kinds.** `MCP.Writer` (lazy start, no idle stop,
  stop before every CLI job), `MCP.Tools`, `Runner.MCP` (`diary_write` ->
  `mempalace_diary_write`, topic default `"general"`; failure inferred from
  `success == false` or an `error` key; lock-refusal text -> `lock_refused`; write
  timeout kills the writer and fails the job). Extend the `test/support` fake
  backend with scripted `tools/call` outcomes (success, error key, lock refusal,
  hang). Tests: allowlist, diary mapping, no retry, timeout, stop-before-CLI.
  Commit: `feat(mcp): add persistent writer for queued write jobs`.
  Review fixes: the lock-refusal text is only looked for in an answer that already is a
  failure; `Writer.stop/1` returns `{:error, :stop_timeout}` (the CLI job is then deferred,
  never started) and waits for the OS process after KILL. **Residual race (accepted):** a
  cancel that arrives between the writer's `on_start(os_pid)` and the request being sent
  is only acted on once the worker handles `{:os_pid, ...}`; the request may already be
  written, so a `cancelled` write job may still have been applied.
- **Phase 5 - DONE. Maintenance mode + proxy read allowlist.** `Butler.Maintenance` (ETS),
  `Backend.suspend/resume`, `MCP.suspend/resume`, proxy gating (immediate error
  -32001), read-tool allowlist on `tools/call`. Worker orchestrates enter ->
  drain (<= 30 s) -> suspend -> run -> leave -> resume in an `after`. Tests: no
  request reaches a worker while active; reads allowed during mine; resume on
  failure/timeout/crash; no live MCP worker during the run; write tools refused by
  the proxy. Commit: `feat(mcp): gate the proxy during maintenance jobs`.
- **Phase 6 - HTTP API.** `JobController`, `HealthController`, `JobJSON`,
  `Plugs.APIAuth`, rename `MCPGuard` to `LoopbackGuard`, `/api/v1` scope, endpoint
  body cap, `docs/api.md` (including the mapping from pi-palace's
  `submitDailyMineJob`, `submitMcpToolJob`, `submitMcpToolJobWaiting`; the last one
  loses its blocking semantics and `lockedByMine`). ConnCase tests: 401, 403,
  413, schema errors, `deduplicated`, UI-only kinds refused, sync default dry-run,
  `include_payload` opt-in. Commit: `feat(api): add token-protected async job API`.
- **Phase 7 - Dashboard and cutover.** Delete `Jobs.Watcher`, `Daemon.Control`,
  `Commands.Direct`, `Commands.Guard`, the CLI-based `Commands.Submit`,
  `DaemonLive`, the `:start_queue` flag (engine on by default). Rewrite `JobsLive`
  (stream + `{:job_changed, job}`, filters, cancel/retry; retry of non-idempotent
  kinds needs a confirm), `JobLive` (live output, tail from `result_json`, payload
  hidden for `diary_write`/`mcp_tool`), `LaunchLive` (enqueue; sync apply behind a
  confirm), `MaintenanceLive` (enqueue with confirm, queue position), new
  `WorkerLive` at `/worker`, global maintenance banner in `Layouts`. Update
  `mix butler.demo`, README, AGENTS.md, CONTRIBUTING.md (architecture diagram,
  safety rules, "the Python daemon must be stopped; set write routing to direct").
  Delete tests of removed modules. May be split into one commit per page, each green.
  Commit: `feat(web): switch dashboard to Butler queue and drop Python daemon control`.

## Post-implementation checks (human)

Measure RAM after phase 5 (proxy workers + writer vs old daemon); calibrate the
per-kind timeouts against real mine durations; end-to-end manual run against a
throwaway palace only.
