# Contributing to Butler

Thanks for your interest in Butler, a local Phoenix LiveView dashboard to
monitor and control the MemPalace daemon.

## Setup

The toolchain (Erlang/OTP and Elixir) is managed with [mise](https://mise.jdx.dev):

```sh
mise install      # installs Erlang 29 and Elixir 1.20.3-otp-29
mise run setup    # deps.get + assets
mise run server   # http://localhost:4000
```

Available tasks: `setup`, `server`, `test`, `format`, `lint`, `precommit`.

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
  defmodule Butler.Jobs.Watcher do
    @moduledoc "..."
    use GenServer

    alias Butler.Jobs.Store

    @poll_interval_ms 2_000
    @topic "butler:queue"
  end
  ```

- **Naming**: modules in `CamelCase`, functions/variables/atoms in
  `snake_case`, predicates end with `?`, no `is_` prefix except in guards.
- **Errors**: return `{:ok, value}` / `{:error, reason}` tuples; reserve
  exceptions for programmer errors.
- **Side effects at the edges**: contexts (`Butler.Jobs`, `Butler.Daemon`,
  `Butler.Commands`) hold the logic; LiveViews only call them and render.

## Safety invariants

These are non-negotiable and covered by tests (see also [AGENTS.md](AGENTS.md)):

1. Never read the daemon `token` file.
2. Never call the daemon HTTP API (Butler serves the loopback-only MCP proxy
   routes, but has no HTTP client).
3. The queue SQLite database is opened **read-only**.
4. Every CLI call goes through the `Butler.CLI` behaviour, with an argument
   list (never a shell string) and a timeout. Sole exception:
   `Butler.MCP.Worker` keeps long-lived MCP backend processes (argument list,
   configured binaries, kill by `os_pid`).
5. Tests use [Mox](https://hex.pm/packages/mox) and fixture SQLite databases
   with **synthetic** data. Never put real diary or `mcp_tool` content in
   fixtures, docs or screenshots.

## Tests

- TDD where feasible: write the failing test first.
- External boundaries (CLI, filesystem locations) are mocked or pointed at
  temporary fixtures; tests never touch a real MemPalace installation.

## Commits

- [Conventional Commits](https://www.conventionalcommits.org), single line,
  in English: `feat(jobs): add read-only queue store`.
- Atomic: one logical change per commit, repository green at each commit.
- Everything (code, docs, UI strings, commits) is written in English.
