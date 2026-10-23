# Contributing to Butler

Thanks for your interest in Butler, a local Phoenix LiveView dashboard to
run MemPalace jobs: Butler owns the job queue and the serial worker that
replace the MemPalace Python daemon.

## Setup

The toolchain (Erlang/OTP and Elixir) is managed with [mise](https://mise.jdx.dev):

```sh
mise install      # installs Erlang 29 and Elixir 1.20.3-otp-29
mise run setup    # deps.get + assets
mise run server   # http://localhost:4000
```

Available tasks: `setup`, `server`, `test`, `format`, `lint`, `screenshots`,
`precommit`. `mise run screenshots` regenerates the README screenshots (light
and dark) from `mix butler.demo`; it needs node and a Chromium
(`CHROMIUM_PATH`, default `/usr/bin/chromium`).

## Before every commit

```sh
mix precommit
```

It runs, in order: `compile --warnings-as-errors`, `format --check-formatted`,
`credo --strict` and `test`. The repository must be green at every commit.

## Code conventions

Butler is idiomatic Elixir. Nothing more, nothing less.

- **Formatting**: `mix format` is the only authority.
- **Linting**: `mix credo --strict` must report no issue.
- **Documentation**: every public module has a `@moduledoc`, every public
  function has a `@doc`.
- **Typespecs**: every public function has a `@spec`; shared data shapes get a
  `@type t`.
- **Constants** are lowercase module attributes, grouped at the top of the
  module right after `use`/`alias`/`import`/`require`:

  ```elixir
  defmodule Butler.Jobs.Queue do
    @moduledoc "..."
    use GenServer

    alias Butler.Jobs.Store

    @topic "butler:queue"
    @call_timeout 15_000
  end
  ```

- **Naming**: modules in `CamelCase`, functions/variables/atoms in
  `snake_case`, predicates end with `?`, no `is_` prefix except in guards.
- **Errors**: return `{:ok, value}` / `{:error, reason}` tuples; reserve
  exceptions for programmer errors.
- **State**: Butler's own files (queue database, token) live in the state
  directory resolved by `Butler.Paths`. Tests always point it at a per-test
  tmp dir (`@tag :tmp_dir`), never at a real location.
- **Side effects at the edges**: contexts (`Butler.Jobs`, `Butler.Commands`,
  `Butler.MCP`) hold the logic; LiveViews only call them and render.
- **Job engine in tests**: the application does not start it in the test
  environment (`start_jobs: false`). Tests start their own queue/worker in a
  tmp state dir with `Butler.Test.Engine` (and are `async: false`).

## Safety invariants

These are non-negotiable and covered by tests (see also [AGENTS.md](AGENTS.md)):

1. Butler reads and writes only **its own** token and queue database, in its
   state directory (`BUTLER_STATE_DIR`, dir mode 700, files mode 600; see
   `Butler.Paths`, `Butler.Token`). It never reads `~/.mempalace/daemon/**`
   (the Python daemon's token and queue) and never calls the Python daemon.
2. Butler has no HTTP client; it only serves HTTP (dashboard, `/api/v1`, MCP
   proxy; loopback, `Host`/`Origin` checked).
3. Processes are spawned only through `Butler.CLI` (argument list, timeout,
   kill by `os_pid`) and `Butler.MCP.Worker` (proxy backends and
   `Butler.MCP.Writer`).
4. Every routine CLI write carries `--direct`, never `--daemon` or
   `--background`.
5. Tests use [Mox](https://hex.pm/packages/mox), the fake MCP backend and
   throwaway state dirs, with **synthetic** data. Never put real diary or
   `mcp_tool` content in fixtures, docs or screenshots, and never run
   `repair`, `compress`, `migrate-wings` or `sync --apply` against a real
   palace.

## HTTP API and OpenAPI

The `/api/v1` contract is documented in [docs/api.md](docs/api.md) and
described, code-first with [open_api_spex](https://hex.pm/packages/open_api_spex),
by `ButlerWeb.API.Spec` (the document), `ButlerWeb.API.Schemas.*` (one module
per schema) and the `operation` declarations of `JobController` and
`HealthController`. The document is served at `GET /openapi`, a Swagger UI at
`GET /swaggerui` (both loopback only, no token).

- A new body field goes in **both** `ButlerWeb.API.JobParams` (the validation
  chain, the authority for error codes, messages and fields) and
  `ButlerWeb.API.Schemas.JobRequest`. The schema must never be stricter than
  the rules (a drift test in `test/butler_web/api/render_error_test.exs`
  checks it); `ButlerWeb.API.RenderError` never translates cast errors, it
  re-runs `JobParams.validate/1`. Per-kind payload rules stay in
  `Butler.Jobs.Kinds.validate_payload/2`.
- A new endpoint needs an `operation` and its schemas, and a conformance test
  (`assert_operation_response` / `assert_schema`) in
  `test/butler_web/api/spec_test.exs`.
- Swagger UI is **vendored** (no Node/npm) in `assets/vendor`; it is bundled
  by esbuild into `swagger.js` / `swagger.css` (separate from `app.js`). See
  [assets/vendor/README.md](assets/vendor/README.md) for the version and how
  to update it.

## Tests

- TDD where feasible: write the failing test first.
- External boundaries (CLI, filesystem locations) are mocked or pointed at
  temporary fixtures; tests never touch a real MemPalace installation.

## Commits

- [Conventional Commits](https://www.conventionalcommits.org), single line,
  in English: `feat(jobs): add read-only queue store`.
- Atomic: one logical change per commit, repository green at each commit.
- Everything (code, docs, UI strings, commits) is written in English.
