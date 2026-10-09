# Butler HTTP API (`/api/v1`)

Asynchronous, fire-and-forget job API for pi-palace (its only client). Butler
queues the job and answers at once; the client polls `GET /api/v1/jobs/:id`.

## Access

- Loopback only: peer address, `Host` (`localhost`, `127.0.0.1`, `::1`) and
  `Origin` (when present) are checked (`Plugs.LoopbackGuard`) -> `403 forbidden`.
- `Authorization: Bearer <token>`, compared with `Plug.Crypto.secure_compare/2`
  (`Plugs.APIAuth`) -> `401 unauthorized` (with `WWW-Authenticate: Bearer`).
  The token is Butler's own: `<state dir>/token` (mode 600, default
  `~/.local/state/butler/token`, `BUTLER_STATE_DIR`). Never the Python daemon's.
- Request bodies are capped at 1 000 000 bytes -> `413 too_large`.

## Errors

```json
{"error": {"code": "invalid_payload", "message": "source is invalid", "field": "payload.source"}}
```

| Status | `code` | When |
| --- | --- | --- |
| 400 | `invalid_payload` | malformed JSON, bad body or payload (`field` names the key) |
| 401 | `unauthorized` | missing / wrong token |
| 403 | `forbidden` | not a loopback client |
| 403 | `kind_not_allowed` | `repair`, `compress`, `migrate-wings` (UI-only) |
| 404 | `not_found` | unknown job id |
| 413 | `too_large` | body over 1 MB |
| 422 | `unknown_kind` | kind does not exist |
| 503 | `queue_unavailable` | queue not running |

## `POST /api/v1/jobs`

Body: `{kind, payload, dedupe_key?, priority?}`. Unknown top-level keys are
refused; `palace_path` (top level or in the payload) is refused: Butler always
uses its own palace. `dedupe_key`: string of 1 to 200 characters. `priority`:
integer (default 0).

Answer `202`:

```json
{"job": {"id": "...", "kind": "mine", "state": "queued", "dedupe_key": "k",
         "created_at": "2026-01-01T10:00:00Z", "deduplicated": false}}
```

A dedupe hit (same `dedupe_key`, job still queued or running) also answers
`202` with the **existing** job and `"deduplicated": true`.

### Payloads

Validated at submit time by `Butler.Jobs.Kinds.validate_payload/2`, with the
rules the worker applies when it runs the job: absolute paths, text not
starting with `-`, no NUL byte, positive integers, whitelisted enums, unknown
keys refused.

| Kind | Payload |
| --- | --- |
| `mine` | `source` (required, absolute), `mode` (`projects`/`convos`/`extract`), `wing`, `agent`, `dry_run`, `limit` (positive), `no_gitignore`, `include_ignored[]`, `extract` (`exchange`/`general`), `max_chunks_per_file`, `redetect_origin` |
| `sweep` | `target` (required, absolute) |
| `sync` | `wing?`, `roots[]?`, `dry_run` - **defaults to `true`**; `--apply` only for an explicit `false`, which needs a `wing` or `roots` |
| `diary_write` | `agent_name`, `entry` (required), `topic?` (default `general`), `wing?` |
| `mcp_tool` | `name` (write allowlist: the 13 MemPalace write tools plus `mempalace_kg_supersede`), `arguments` (object, default `{}`) |

`null`, `""`, `false` and `[]` optional values are omitted.

## `GET /api/v1/jobs/:id`

```json
{"job": {"id": "...", "kind": "...", "state": "queued|running|succeeded|failed|cancelled",
         "dedupe_key": null, "created_at": "...", "started_at": null, "finished_at": null,
         "priority": 0, "attempts": 0, "result": null, "error": null}}
```

The payload (verbatim diary / tool content) is only returned with
`?include_payload=true`.

## `GET /api/v1/health`

```json
{"ok": true, "worker": "idle", "active_job_id": null, "maintenance": false,
 "counts": {"queued": 0, "running": 0, "succeeded": 0, "failed": 0, "cancelled": 0}}
```

`worker` is `idle`, `running`, `blocked` (legacy Python daemon alive) or
`booting`; `unavailable` with `ok: false` and status `503` when the worker or
the queue is down. `maintenance` is true while a repair / compress /
migrate-wings job owns the palace.

## Mapping from pi-palace (`src/daemon-client.ts`)

pi-palace today runs `python -c` against `mempalace.daemon.submit_job`. With
Butler it sends `POST /api/v1/jobs` with the token from Butler's state dir.

| pi-palace | Butler |
| --- | --- |
| `submitDailyMineJob(sessionsDir, wing, limit, dedupeKey)` | `{"kind":"mine","dedupe_key":"pi-daily-sessions-mine","payload":{"source":sessionsDir,"mode":"convos","wing":wing,"agent":"mempalace","extract":"exchange","limit":limit}}`. `dedupeKey = null` -> omit `dedupe_key`. `success` = HTTP `202`; `deduplicated: true` is a success too (daily job already pending). |
| `submitMcpToolJob(name, args)` | `{"kind":"mcp_tool","payload":{"name":name,"arguments":args}}`, no `dedupe_key`. `jobId` = `job.id`, `state` = `job.state`. |
| `submitMcpToolJobWaiting(name, args)` | Same `POST`, then the caller **polls** `GET /api/v1/jobs/:id` until `succeeded` / `failed`. Butler has no `wait`: the blocking semantics move to the client. `lockedByMine` disappears: Butler re-queues a lock-refused job itself (cooldown, `BUTLER_LOCK_BACKOFF_SECONDS`), so the job simply stays `queued`; a `queued` job with `error.class == "LockHeldByOtherProcess"` is the equivalent signal. `succeeded` -> `job.result.result` holds the tool's JSON; `failed` -> `job.error.message`. |

Differences to handle on the client:

- `limit: 0` (unlimited in `mempalace mine`) is refused (`limit` must be a
  positive integer): **omit** `limit` for unlimited.
- Send `include_ignored`, `no_gitignore`, `redetect_origin`, `dry_run`,
  `max_chunks_per_file` only when meaningful; the defaults above (`false` / `[]`
  / `null`) are accepted and omitted.
- `ensureDaemonRunning` (`mempalace daemon status|start`) is not needed: use
  `GET /api/v1/health` (`ok: true`).
- `mempalace_checkpoint` (`checkpoint-tool.ts`) is an `mcp_tool` job named
  `mempalace_checkpoint`; its `{items, diary?}` goes in `arguments`. The
  KG tools (`mempalace_kg_add`, `mempalace_kg_supersede`,
  `mempalace_kg_invalidate`) are all in the write allowlist.
