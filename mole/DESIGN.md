# mole — architecture

mole is the shared foundation for a family of small Nushell modules that wrap
data-source CLIs/APIs behind typed, completion-aware verbs. This document is the
interface spec: the tiers, what each one may depend on, the driver contract, the
configuration model, and how the suites run.

## 1. The one principle: dependencies point one way

```
   ┌──────────────────────────┐
   │  mole  (core)            │  mod.nu · cfg.nu  → user commands (`mole cfg …`, `mole query …`)
   │   lib/ config conn cache │  lib/*.nu         → plumbing, imported per concern by the tiers above
   │        query editor      │
   │        complete          │
   └────────────▲─────────────┘
                │                  pure LIBRARIES (file modules, import NOTHING impure):
   ┌────────────┴─────────────┐    mole-sql/sql.nu · mole-myql/myql.nu (← mole-sql) · mole-promql/promql.nu
   │        DRIVERS           │    mole-psql · mole-mysql · mole-mariadb · mole-trino · mole-duckdb
   │  (mod.nu per data source)│    mole-mongodb · mole-victorialogs · mole-prometheus · mole-victoriametrics
   └──────────────────────────┘    TOOLS over core: mole-mermaid · mole-sqls · mole-zellij
```

- **Core** never imports, enumerates, or generates anything about the modules
  above it. Installing a driver is placing it on `$env.NU_LIB_DIRS` and adding one
  `use` line — no umbrella, no manifest, no codegen.
- **Pure libraries** are data-in / data-out: no connection, no CLI, no cache, no
  `$env`. Anything dialect-specific is *injected* by the caller — a parameter when
  data suffices (`nulls`, an `ops` table), a closure when it doesn't (a type map).
  A library may import another pure library (`mole-myql` ← `mole-sql`), never core
  or a driver. Where a driver would otherwise copy orchestration, the library
  exposes a **plan**: `sql where-plan` returns the completion candidates *or* the
  probe SQL to run; the driver runs it. The library stays pure, the driver stays thin.
- **Drivers** own all I/O and policy: how to exec the CLI/API, the introspection
  queries, the type map, the danger regex, cache keys, and the user verbs.

Imports are always `use module` (never `use module *`) and always discovery
paths resolved through `$env.NU_LIB_DIRS` (`use mole/lib/conn.nu`,
`use mole-sql/sql.nu`), never `../` relative paths; intra-module imports stay `./`.
Pure libraries are file modules (`use mole-sql/sql.nu` → `sql …`); drivers and
tools ship a `mod.nu` (`use mole-psql` → `mole-psql …`).

## 2. Constraints that drive the design (verified on 0.116)

| Fact | Consequence |
|------|-------------|
| `use X` is a parse keyword; `use $var` is a **parse error**. | Modules can't be discovered/loaded dynamically. The user lists the modules they want, one `use` line each. |
| **Direct** top-level `use mod` runs its `export-env`; multiple accumulate into `$env`. | Each driver's `export-env` self-registers into `$env.MOLE_REGISTRY`. |
| `use mod` (no `*`) prefixes commands with the module name; a private `use` does not re-export. | `mod.nu` imports `./lib/*` privately, so `use mole` never leaks plumbing. |
| A file module is imported **with its `.nu` extension**; the module name is the basename. | Concern files compose as `conn resolve`, `cache fetch`, `sql where-plan`, … |
| `$env.NU_LIB_DIRS` is read at **`nu` startup**; `use` resolves at **parse time**. | Set `NU_LIB_DIRS` before launching `nu`. |
| An unknown `a b` call parses as the **external** command `a`, not an error. | A missing helper is a *runtime* "command not found", so `use mole-x` loading is not a check — the dry-run suites are. |
| An imported command's bare calls re-resolve in the **importer's** scope. | A driver exporting `select`/`update`/`insert` shadows the builtins inside `mole-sql`, which therefore calls them through `core-select`/… aliases. |
| A completer is a named `def` bound at import; Nushell can't complete inside a `[...]` literal. | Multi-value flags are ONE comma string (`--by a,b`); `complete csv` splits it in the verb, `complete csv-extend` keeps the typed prefix in the completer. |

## 3. Command surface

`use mole` exposes **only management commands**: `mole cfg show/file/dir/edit`
(connection config) and `mole query edit/show/dir` (saved queries under
`~/.config/mole/queries`). Everything else is a driver verb.

## 4. The lib (plumbing), imported per concern

| Import | Commands |
|--------|----------|
| `use mole/lib/config.nu`   | `config dir/file/querydir` — XDG-aware paths |
| `use mole/lib/conn.nu`     | `conn list/names/resolve/with/override/redact/register/set-current` |
| `use mole/lib/cache.nu`    | `cache path/read/write/stale/fetch/clear` — `fetch file ttl {|| build}` is the one memoize primitive (it stamps `meta.refreshed_at`) |
| `use mole/lib/query.nu`    | `query resolve/confirm/check/is-dangerous` — query text from positional → `--file` → stdin → `$EDITOR`; the y/N prompt; the `complete`-record check; the quote-aware danger test |
| `use mole/lib/editor.nu`   | `editor launch target --cwd dir` — the ONE way `$EDITOR` is run (directly, flags split, vim cwd pinned) |
| `use mole/lib/complete.nu` | cross-driver completers `complete connection/queryfile`; the contextual toolkit `complete token/csv/csv-extend/sort-csv/flag/positionals/lead-arg/conn-ctx/catalog-ctx` |

The contextual toolkit is the part every driver builds on: `flag` and
`positionals` read the partial line through the parser (quote-aware), `conn-ctx`
resolves the connection a line targets (typed `-c` → session current → the
`__current__` mirror `conn set-current` writes, because completion often can't see
the session `$env`), `catalog-ctx` reads that connection's cached catalog, and none
of them ever throws — a Tab never errors.

Core ships *mechanism*; each driver owns *policy*.

## 5. The self-assembling registry — `$env.MOLE_REGISTRY`

A set of loaded driver names (`{<driver>: true}`), built at load by each driver's
own `export-env`:

```nushell
use mole/lib/conn.nu
export-env { conn register "psql" }   # upserts {psql: true}; seeds $env.MOLE_CURRENT
```

No manifest, no file read; a driver announces just its own name. Its consumer is
`conn`'s `--driver` completer. Connections resolve from the driver-keyed config
directly (§7), so resolution itself needs no registry lookup.

## 6. Driver contract

A `mole-<tool>` directory must:

1. `use mole/lib/<concern>.nu` for the plumbing it needs, and the pure libraries
   it composes (`use mole-sql/sql.nu`). Never `*`.
2. In `export-env`, call `conn register "<driver>"`.
3. Define a **driver-scoped** connection completer and use it on every verb:
   `def complete-connection [] { conn names "<driver>" }` — a driver's verbs never
   suggest another driver's connections. (Core's own `complete connection` is the
   cross-driver one, for `mole cfg show`.)
4. Expose `set-connection <name>` as a thin `--env` wrapper over `conn set-current`.
5. **Pair verbs**: every structured, completing verb (a query-language subset such
   as `select`, `stats`, `find`) has a raw brother (`raw-query`, `raw-stats`) that
   takes the native query text verbatim. Raw verbs run through `query resolve` so
   the text can arrive as a positional, a saved `--file`, or stdin.
6. Every verb that **composes** a query exposes `--dry-run(-n)` returning exactly
   `{connection: ($conf | conn redact), query: <composed string>}` without running.
   This is the regression surface: the `@example … --result` blocks and the
   driver suites assert on it.
7. Writes prompt (`query confirm`, skipped by `--yes`) and refuse an unfiltered
   `UPDATE`/`DELETE` without `--all`; raw verbs prompt when `query is-dangerous`
   matches the dialect's danger regex.
8. Cache what completion needs (schema or catalog) under `cache path "<driver>" …`
   through `cache fetch`, and build completers from the toolkit: the SQL drivers'
   `--where` completer is a few lines over `sql where-plan` plus the driver's
   bounded probe (`*-exec --probe`). The probe is the one completer that touches
   the network on Tab: time-boxed, best-effort, and empty on any failure.

## 7. Configuration model

Connections live at `~/.config/mole/connections.yaml` (honors `$XDG_CONFIG_HOME`),
grouped into a **map keyed by driver** — one section per driver, so each section
is shape-homogeneous:

```yaml
connections:
  psql:                       # section key = driver (mole-psql)
    - name: prod-pg
      host: db.example.com
      port: 5432
      user: alice
      password: hunter2
      database: app
  victorialogs:
    - name: prod-logs
      url: https://vl.example.com
```

- The section key IS the `driver`; `conn list` flattens the map and tags every
  record with it.
- **Names are globally unique.** The same name under two sections is rejected at
  read with an error naming both, so `conn resolve <name>`, `mole cfg show <name>`,
  the mole-zellij picker and mole-sqls never have to disambiguate.
- **Completion is driver-scoped** (`conn names "<driver>"`, see §6).
- The active connection is **per-driver**: `$env.MOLE_CURRENT = {psql: "prod-pg",
  victorialogs: "prod-logs"}`, set by each driver's `set-connection`, which also
  mirrors the name into `<cache>/<driver>/__current__.nuon` for completion. A
  current name that no longer exists in the file errors with a message saying so.
- The old flat `connections:` list is rejected at read.

## 8. Tests

Every module keeps a nutest suite under `<module>/tests` (`use std/testing *`,
`@test`). Pure libraries test their functions directly; drivers test their verbs
through `--dry-run` against a throwaway XDG config, and the `schema` views
against a catalog seeded with `cache write` (with a real `meta.refreshed_at`, or
`cache fetch` would rebuild it).

Run everything from the workspace root:

```nushell
nu run-tests.nu              # every */tests
nu run-tests.nu --path mole-sql
nu run-tests.nu --fail       # non-zero exit on failures (CI)
```

`$env.NU_LIB_DIRS` must carry the workspace root and a directory containing
`nutest/`. The runner hands the lib path to nutest's `nu --no-config-file`
subprocesses as a colon string (a list-valued `NU_LIB_DIRS` is dropped on spawn),
which is why running a cross-module suite by hand fails without it. The root
`.github/workflows/tests.yml` runs the same script.

Completers are not unit-testable (private, `@`-bound); drive them through the real
engine: write `use mole-psql\nmole-psql select --from users -c pg --where st` to a
file and run `nu --ide-complete <byte offset> <file>` with `XDG_CONFIG_HOME` /
`XDG_CACHE_HOME` pointing at a seeded config and cache.
