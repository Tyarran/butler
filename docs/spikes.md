# Phase 0 spikes: palace lock, CLI routing, MCP classification

Findings for the plan "Butler replaces the MemPalace Python daemon".
Everything below was measured against **MemPalace 3.10.0** (uv tool install,
Python 3.14) on a **throwaway palace** with synthetic files. Nothing touched
`~/.mempalace`, the real palace, the daemon `token` or the daemon HTTP API.

## Test harness (isolation)

```sh
tmp=$(mktemp -d /tmp/spike.XXXXXX)
mkdir -p $tmp/home $tmp/cfg $tmp/state $tmp/src
ln -s ~/.cache $tmp/home/.cache            # embedding model cache only
export HOME=$tmp/home                      # locks live under $HOME/.mempalace/locks (see Q1)
export MEMPALACE_CONFIG_DIR=$tmp/cfg
export MEMPALACE_DAEMON_STATE_ROOT=$tmp/state
export MEMPALACE_PALACE_PATH=$tmp/palace
# every call: mempalace --palace $tmp/palace ...
```

`$tmp/state` stayed empty during the whole session (no daemon state was ever
created), and `$tmp/home/.mempalace/locks/` is where the lock appeared. The
temp directory was deleted at the end. A MCP client was driven by hand over a
FIFO (line-delimited JSON-RPC, `initialize` then `tools/call`). RSS was read
from `/proc/<pid>/status`, and for CLI runs from `wait4()` `ru_maxrss` (no
`/usr/bin/time` on this host).

## Q1. Does `mempalace-mcp` keep a palace writer lease?

**Yes, after the first mutating tool call, until the process exits.**

Source (`mempalace/mcp_server/_guards.py`, "MCP peer-writer guard (#1818)"):
the lease is the per-palace `mine_palace_lock` (an `flock` on
`$HOME/.mempalace/locks/mine_palace_<hash>.lock`), taken lazily by the first
tool in `_MUTATING_TOOLS`, kept for the process lifetime and released by an
`atexit` handler (SIGTERM and SIGHUP are routed through `sys.exit` so it runs).
Read tools never take it. Logstream tools (`event_*`, `task_create`,
`artifact_put`, `patch_submit`) are exempt (own sqlite file).

### Idle MCP (reads only) does not block a CLI mine

```text
$ mempalace-mcp --palace $tmp/palace   # initialize, mempalace_status, mempalace_search
$ mempalace --palace $tmp/palace mine $tmp/src2 --direct --wing spike2
  Drawers filed: 1            exit=0
```

### After a write, the MCP holds the lock and refuses every CLI writer

```text
> mempalace_kg_add {"subject":"Spike","predicate":"tests","object":"locks"}   -> success
$ cat $HOME/.mempalace/locks/mine_palace_*.lock
 206941 /home/romain/.local/bin/mempalace-mcp --palace /tmp/spike.OgxkdX/palace
$ mempalace --palace $tmp/palace mine $tmp/src3 --direct --wing spike3
stderr: mempalace: palace /tmp/spike.OgxkdX/palace is held by PID 206941 (/home/romain/.local/bin/mempalace-mcp --palace /tmp/spike.OgxkdX/palace); wait for it to finish or stop the holder before retrying
exit=1
```

The same happened after `mempalace_diary_write` and `mempalace_kg_supersede`
(all of them succeeded and the lease stayed held). The lease is **not** released
by being idle. `mempalace_reconnect` is not a release path either according
to the source (the release callers are `atexit` and the HTTP shutdown path;
not re-verified with a CLI mine after a reconnect).

### The lease is released when the MCP process exits

* closing its stdin (EOF) makes it exit cleanly; the next mine succeeded;
* `kill <pid>` (SIGTERM) made the process exit (observed). The lock file then
  still names the dead pid, but `flock` is released by the kernel on process
  death, so it is re-acquirable (from the lock code, not re-run after SIGTERM).

By default an MCP server also exits by itself after 8 h without a request
(`MEMPALACE_MCP_IDLE_HOURS`, default 8, `0` disables).

### Reverse direction: a CLI/other writer holds the lock while the MCP is alive

A throwaway holder (`mine_palace_lock` for 25 s) was started, then a fresh MCP:

```text
> mempalace_kg_add          -> error -32001 "Peer MCP writer active; this server is read-only for mutating tools"
                              data.failure_kind = "peer_contention"
                              data.reason = "... palace <p> is held by PID 209565 (hold.py ...); wait for it to finish or stop the holder before retrying"
> mempalace_diary_write     -> same error
> mempalace_search          -> OK (reads keep working)
(25 s later)
> mempalace_kg_add          -> success   (ownership is retried at every mutating request, no restart needed)
```

### Other observations

* `mine --dry-run --direct` takes **no** lock (ran fine while the MCP held the lease).
* `sync --dry-run --direct` **does** take the lock (refused while the MCP held it).
* A long-lived idle MCP does **not** go stale after external CLI writes: after a
  direct mine added a drawer, `mempalace_search` found it immediately, without
  `mempalace_reconnect` (reconnect also worked: `{"success": true}`).

### RSS (kB from `/proc`, CLI figures are peak `ru_maxrss`)

| Process | RSS |
| --- | --- |
| `mempalace-mcp` just after `initialize` | ~94 MB |
| after first read calls (`status`, `search`: embedder loaded) | ~274-280 MB |
| after `kg_add` | ~278 MB |
| after `diary_write` | ~288 MB |
| after a later search | ~294 MB |
| `mempalace mine` (3 tiny files, 1.8 s) | ~280 MB peak |
| `mempalace mine` refused by the lock | ~86 MB peak, <1 s |
| `sweep` (1 transcript) | ~125-280 MB |
| `compress` / `repair` | ~130-280 MB |

The "1.5 GB" quoted for the real MCP is therefore data/palace dependent (HNSW,
big collection); on an empty palace the embedder dominates at ~280 MB. The
write itself adds almost nothing: the cost is the long-lived process.

### Consequence for the design

A persistent full `mempalace-mcp` **cannot coexist** with CLI jobs
(`mine`/`sweep`/`sync`/`repair`/`compress`/`migrate-wings`) once it has served a
single write: every CLI job is refused until it exits. Options:

1. **Idle-stop writer (recommended default):** the serial worker owns the
   palace. Before a CLI job it stops the writer (close stdin, wait for exit,
   kill by `os_pid` after a timeout), runs the job, and starts the writer
   lazily on the next `mcp_tool` job (or the next MCP proxy write). Reads can
   be served by an idle (read-only, lease-free) process, so a **separate**
   long-lived reader costs RAM but never blocks jobs; the writer is the one that
   must be disposable.
2. **Persistent writer, no CLI jobs:** only valid if mine/sweep/sync are run
   *through* the writer (`mempalace_mine`/`mempalace_sync` are MCP tools; the
   code comments say the lock is process-re-entrant for the owner). **Not tested
   in this spike**; needs its own spike before choosing it. repair, compress and
   migrate-wings have no MCP equivalent, so they would still need the writer
   stopped.
3. `MEMPALACE_MCP_ALLOW_PEER_WRITER=1` bypasses the guard but only for backends
   that do not require a single writer; the default chroma backend does
   (`backend_requires_single_writer`), so **do not rely on it**.

Also: the lock file is under **`$HOME/.mempalace/locks/`**, not in the palace
directory. Every Butler-spawned process (CLI and MCP) must run with the **same
`HOME`** (and `MEMPALACE_CONFIG_DIR` / palace path), or they will not see each
other's lock and will corrupt the palace instead of being refused. If the
persistent MCP is kept, set `MEMPALACE_MCP_IDLE_HOURS=0` (otherwise it exits
after 8 idle hours and the worker must handle an unexpected exit).

## Q2. `sweep`, `sync` and the other commands: flags and lock refusal

### argv shapes (from `--help`)

```text
mempalace [--palace P] mine DIR [--mode {projects,convos,extract} | --source ADAPTER] [--wing W]
          [--no-gitignore] [--include-ignored PATHS] [--agent A] [--limit N] [--redetect-origin]
          [--dry-run] [--daemon | --direct] [--background] [--extract {exchange,general}]
          [--max-chunks-per-file N] [--include-subagents] [--backend B]
mempalace [--palace P] sweep TARGET [--daemon | --direct] [--background]      # TARGET: .jsonl file or dir
mempalace [--palace P] sync [DIR] [--wing W] [--root R]... [--dry-run] [--apply]
          [--daemon | --direct] [--background]      # --apply needs --wing or a root; Butler never passes it
mempalace [--palace P] repair [rebuild-index] [--yes] [--confirm-truncation-ok]
          [--mode {legacy,max-seq-id,from-sqlite}] [--source S] [--archive-existing]
          [--segment S] [--from-sidecar F] [--backup | --no-backup] [--dry-run]
mempalace [--palace P] compress [--wing W] [--dry-run] [--config entities.json]
mempalace [--palace P] migrate-wings [--dry-run] [--yes]
```

* `mine`, `sweep`, `sync` (and `init`) accept **`--direct`** (and
  `--daemon`, `--background`, mutually exclusive `--daemon | --direct`).
  `--background` requires a daemon route and is an error under `--direct`.
* `repair`, `compress`, `migrate-wings` have **no routing flags**: they never go
  through the daemon (`cli_write_routing.py`: "Maintenance operations ...
  deliberately remain outside this policy"), so they are always direct.
* `--palace` is a **global** option and goes before the subcommand.
* `sync`: `--dry-run` is the default and `--apply` overrides it; Butler must
  always pass `--dry-run` (`sync --apply` is never exposed).
* `repair --yes` / `migrate-wings --yes` skip prompts; with stdin closed
  (`</dev/null`) the commands did not hang.

### Lock refusal text, per command (palace held by `mempalace-mcp`)

Source: `palace/palace_lock.py` raises
`MineAlreadyRunning("palace {path} is held by {holder}; wait for it to finish or stop the holder before retrying")`,
where `{holder}` is `PID <n> (<cmdline>)`. How each command surfaces it:

| Command (`--direct`) | exit | where | text |
| --- | --- | --- | --- |
| `mine DIR` | **1** | stderr | `mempalace: palace <p> is held by PID <n> (<cmd>); wait for it ...` |
| `sync DIR --dry-run` | **1** | stderr | same `mempalace: palace ...` line (banner on stdout) |
| `sweep DIR` | **2** | stderr | `sweeper: sweep failed on <file>: palace <p> is held by ...` + `WARNING: sweep failed on ...` + `WARNING: 1 file(s) failed to sweep` (stdout `Swept 0/1 files`) |
| `sweep FILE.jsonl` | **1** | stderr | Python **traceback** ending `mempalace.palace.MineAlreadyRunning: palace <p> is held by ...` |
| `compress` | **1** | **stdout** | `Error storing compressed drawers: palace <p> is held by ...` |
| `repair --yes` | **1** | **stdout** | `Repair failed: palace <p> is held by ...` |
| `mine --dry-run` | 0 | - | no lock taken, never refused |
| `migrate-wings` | n/a | - | nothing to migrate on the test palace, refusal path not exercised (it writes through the same locked collection API as `compress`) |

Exit codes are **not** a reliable signal (1 or 2, and 1 also means other
failures). The output stream also varies (stdout for compress/repair).

### Detecting `lock_refused` in Butler

Treat a CLI run as `lock_refused` when the exit status is non-zero **and** the
combined stdout+stderr matches:

```elixir
@lock_refusal ~r/palace .+ is held by .+; wait for it to finish or stop the holder before retrying|MineAlreadyRunning/s
```

(The daemon's own constant is `LOCK_REFUSAL_ERROR_CLASS = "LockHeldByOtherProcess"`
in `daemon.py`/`service.py`; it only exists in the Python daemon's JSON results,
never in CLI output, so Butler must define its own `error_class`, e.g.
`"LockHeldByOtherProcess"` for compatibility with the job UI.) Treat it as
retriable with backoff (the Python daemon does the same, see
`MEMPALACE_DAEMON_LOCK_BACKOFF_SECONDS`) without consuming a retry attempt.
For MCP writes the signal is the JSON-RPC error code **-32001** with
`data.failure_kind == "peer_contention"`.

## Q4. `mempalace_kg_supersede` classification

* It **is** registered in `mcp_server.schemas.TOOLS` (45 tools in total,
  `tools/list` returns the same 45 names), handler `tool_kg_supersede`, and it
  is in `_guards._MUTATING_TOOLS` (takes the writer lease).
* It is in **none** of `READ_TOOLS` / `WRITE_TOOLS` / `MAINTENANCE_TOOLS` of
  `service.py`; `classify_tool("mempalace_kg_supersede") == "unknown"`.
  Consequence: the Python daemon's `mcp_tool` job (`service.py`, "daemon
  mcp_tool only accepts write tools; ... is unknown") **rejects it**. It works
  through a direct MCP call (verified: `{"success": true, "superseded": "locks"}`),
  so Butler must carry its **own** allowlist rather than reuse `classify_tool`.
* Also unclassified (all in `TOOLS`): `mempalace_mesh_peers`, `mempalace_event_append`,
  `mempalace_task_create`, `mempalace_event_list`, `mempalace_event_wait`,
  `mempalace_event_ack`, `mempalace_artifact_put`, `mempalace_artifact_get`,
  `mempalace_patch_submit`.

Classification sets in `service.py` (MemPalace 3.10.0), names only:

```text
READ_TOOLS (19):
  mempalace_status mempalace_list_wings mempalace_list_rooms mempalace_get_taxonomy
  mempalace_get_aaak_spec mempalace_traverse mempalace_find_tunnels mempalace_graph_stats
  mempalace_list_tunnels mempalace_list_hallways mempalace_follow_tunnels mempalace_search
  mempalace_check_duplicate mempalace_get_drawer mempalace_list_drawers mempalace_diary_read
  mempalace_kg_query mempalace_kg_stats mempalace_kg_timeline

WRITE_TOOLS (13):
  mempalace_add_drawer mempalace_checkpoint mempalace_delete_by_source mempalace_delete_drawer
  mempalace_update_drawer mempalace_diary_write mempalace_kg_add mempalace_kg_invalidate
  mempalace_create_tunnel mempalace_delete_tunnel mempalace_delete_hallway
  mempalace_hook_settings mempalace_memories_filed_away

MAINTENANCE_TOOLS (3):
  mempalace_mine mempalace_sync mempalace_reconnect
```

### Consequence for the `mcp_tool` allowlist

Allow (write, serialised through the single worker): the 13 `WRITE_TOOLS` **plus
`mempalace_kg_supersede`** (explicit addition, it is the documented way to
replace a single-valued fact). Do **not** allow `mempalace_mine`,
`mempalace_sync` (they have dedicated job kinds with `--dry-run` forced for
sync) nor `mempalace_reconnect` through the generic `mcp_tool` path. Logstream
tools (`event_*`, `task_create`, `artifact_put`, `patch_submit`) are exempt from
the peer-writer lease and need a separate decision (not part of the write
queue). Keep the allowlist as an explicit list in Butler (with a test that
fails when a new MemPalace tool is unclassified), never derived from
`classify_tool`.

## Q5. Forcing `direct` and preventing daemon auto-start

Resolution (`cli_write_routing.resolve_cli_write_routing` and
`MempalaceConfig.resolve_write_routing("cli")`), first match wins:

1. `--direct` / `--daemon` flag (mutually exclusive);
2. env `MEMPALACE_CLI_WRITE_ROUTING`;
3. env `MEMPALACE_WRITE_ROUTING`;
4. config `write_routing.cli` (in `config.json` under `MEMPALACE_CONFIG_DIR` /
   `~/.config/mempalace/`);
5. config `write_routing.default`;
6. default `direct`.

(For hooks: `MEMPALACE_HOOK_WRITE_ROUTING`, legacy `MEMPALACE_HOOKS_DAEMON`,
`hooks.daemon` in config. Hooks are not used by Butler.) Values are
`direct | prefer | require`; under `prefer` or `require` an interactive CLI
write **auto-starts** the daemon (`daemon_can_start=True`, no health probe).

**Contradiction with the current setup:** the maintainer's real
`~/.config/mempalace/config.json` has `write_routing: {"cli": "require", "hooks": "require"}`
(only those keys were read). So a bare `mempalace mine ...` **would** go to / start
the Python daemon. Butler must therefore never rely on config defaults.

Verified on the throwaway config (`{"write_routing":{"cli":"require",...}}`), via the
pure resolver (no process spawned):

```text
config cli=require, no flag                              use_daemon=True  use_direct=False source=config write_routing.cli
config cli=require, --direct                             use_daemon=False use_direct=True  source=--direct
config cli=require, env MEMPALACE_CLI_WRITE_ROUTING=direct  use_daemon=False use_direct=True source=MEMPALACE_CLI_WRITE_ROUTING
config cli=require, env MEMPALACE_WRITE_ROUTING=direct   use_daemon=False use_direct=True source=MEMPALACE_WRITE_ROUTING
```

and end to end: with `MEMPALACE_CLI_WRITE_ROUTING=require` in the environment,
`mempalace --palace P mine DIR --direct` executed in-process (it reached the
lock and was refused by the MCP holder, exit 1) and `$MEMPALACE_DAEMON_STATE_ROOT`
stayed empty, no daemon process appeared. The positive case (no `--direct`
under `require`, which would auto-start a daemon) was deliberately **not**
executed.

### Required flags/env for Butler CLI calls

* Always append **`--direct`** to `mine`, `sweep`, `sync`, and `init` if ever used.
  `repair`, `compress`, `migrate-wings` are never routed.
* Belt and braces on every spawned process: `MEMPALACE_CLI_WRITE_ROUTING=direct`
  and `MEMPALACE_WRITE_ROUTING=direct` (covers a future command that forgets the
  flag), plus `MEMPALACE_HUB_FORWARD=0` (`cli/_hub.py`: a direct `mine` or
  `search` otherwise forwards to a live `mempalace serve` hub over HTTP,
  which Butler must never do; no hub exists for a palace without a registry
  file, but disable it anyway).
* Pass the palace as `--palace <path>` (global flag, before the subcommand).
* Same `HOME` / `MEMPALACE_CONFIG_DIR` for CLI and MCP processes (lock location, Q1).
* Keep `Butler.CLI` arg-list + timeout + kill by `os_pid`. Note the CLI
  process may spawn nothing else (observed single process).

## Summary of contradictions with the plan

1. **Persistent writer vs CLI jobs**: incompatible after the first write
   (Q1). The writer must be stopped around CLI jobs (or all work must go
   through it, untested).
2. **`kg_supersede` is "unknown"** to the Python service classification, so
   the plan to mirror `classify_tool` would reject it; Butler needs its own allowlist.
3. **Exit code and stream of a lock refusal are inconsistent** (1 or 2; stderr
   or stdout; traceback for `sweep FILE`). Detect by regexp on both streams, not
   by exit code.
4. **Real config has `write_routing.cli = require`**: `--direct` (and the env
   overrides) is mandatory, not optional.
5. **Lock directory is `$HOME`-based**: processes with different `HOME` do not
   exclude each other.
