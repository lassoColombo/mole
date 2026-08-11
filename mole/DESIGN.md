# mole — architecture

mole is the shared foundation for a family of small Nushell modules that wrap
data-source CLIs/APIs (`mole-sql`, `mole-vlogs`, …) behind typed, completion-aware
verbs. This document is the interface spec.

> **Scope note.** Submodule *management* (`mole submodules …`) and the
> version/compatibility contract were removed for now. mole core is currently
> connection-config + saved-query management plus the shared `lib/` plumbing;
> submodules still self-register at load. Installing/updating a submodule is plain
> `git` by hand. This spec describes that reduced surface.

## 1. The one principle: submodules depend on mole, never the reverse

```
        ┌──────────────┐
        │     mole     │   mod.nu · cfg.nu   → user commands
        │  ┌────────┐  │   lib/*.nu          → plumbing (private)
        │  │  lib   │  │
        └──┴────────┴──┘
              ▲
     ┌────────┼────────┐   each submodule imports the lib CONCERNS it needs
┌────────┐ ┌────────┐ ┌────────┐   (e.g. `use mole/lib/conn.nu`)
│mole-sql│ │mole-…  │ │mole-vlg│   and self-registers at load
└────────┘ └────────┘ └────────┘
```

mole **never imports, enumerates, or generates anything about submodules.**
Installing a submodule is just placing it on `$env.NU_LIB_DIRS` (clone it
anywhere that path covers) — no umbrella, no `sync`/codegen, and **no assumed
on-disk layout**: cross-module imports go through `NU_LIB_DIRS` discovery
(`use mole/lib/conn.nu`), never `../` relative paths. Import rule everywhere:
**`use module`, never `use module *`**.

## 2. Constraints that drive the design (verified on 0.114.1)

| Fact | Consequence |
|------|-------------|
| `use X` is a parse keyword; `use $var` is a **parse error**. | Modules can't be discovered/loaded dynamically. The user lists the submodules they want, one `use` line each. |
| **Direct** top-level `use mod` runs its `export-env`; multiple accumulate into `$env`. | Because the user `use`s each submodule directly, their `export-env` blocks run and **self-assemble** `$env.MOLE_REGISTRY`. |
| `use mod` (no `*`) prefixes commands with the module name; a private `use` (not `export use`) does not re-export. | Prefix = dir name (`use mole-sql` → `mole-sql select`). `mod.nu` imports `./lib/*` privately, so `use mole` never leaks plumbing. |
| A file module is imported **with its `.nu` extension** (`use ./lib/conn.nu`); the module name is the basename (`conn`). | Concern files compose as `conn resolve`, `cache path`, … |
| A relative `use ../x` hard-codes an on-disk layout; a bare `use x/y.nu` resolves against `$env.NU_LIB_DIRS`. | Cross-module imports use **bare discovery paths** (`use mole/lib/conn.nu`, `use mole-sql/sql.nu`); submodules need not sit beside `mole/`. Intra-module imports stay `./`. |
| `$env.NU_LIB_DIRS` is read at **`nu` startup**; `use` resolves at **parse time**. | Set `NU_LIB_DIRS` as an env var *before* launching `nu` — a `$env.NU_LIB_DIRS = …` assignment in the same file runs too late for that file's own `use`. |
| A command's `@"completer"` binding is captured on import. | Callers annotate `@"complete connection"`. |

## 3. Layout & command surface

```
<workspace>/
├── mole/
│   ├── mod.nu    # composition + `mole query edit/show/dir`
│   ├── cfg.nu    # `mole cfg show/file/dir/edit`
│   └── lib/      # plumbing concerns (private to mole; imported by submodules)
│       ├── config.nu · conn.nu · cache.nu · query.nu · complete.nu
├── mole-sql/    mod.nu      (`use mole/lib/*.nu`)
└── mole-vlogs/  mod.nu
```

`use mole` exposes **only management commands**: `mole cfg …` (connection config)
and `mole query …` (saved queries). `mod.nu` composes `cfg.nu` with `export use
./cfg.nu` (whole-file, no `*`), so its leaf defs become `mole cfg show`, etc.; the
`query` verbs are defined directly in `mod.nu`.

## 4. The lib (plumbing), imported per concern

Each concern is a file under `lib/`, imported individually with its `.nu`
extension. Submodules import only what they need; `use mole` never exposes any:

| Import | Commands |
|--------|----------|
| `use mole/lib/config.nu`  | `config file`, `config querydir` |
| `use mole/lib/conn.nu`    | `conn list`, `conn resolve`, `conn override`, `conn with` |
| `use mole/lib/cache.nu`   | `cache path/read/write/stale/clear` |
| `use mole/lib/query.nu`   | `query resolve`, `query confirm`, `query check` |
| `use mole/lib/complete.nu`| `complete connection`, `complete queryfile` |

Core ships *mechanism*; each submodule owns *policy* (what's dangerous, how to
type results, how to exec).

## 5. The self-assembling registry — `$env.MOLE_REGISTRY`

A set of loaded driver names (`{<driver>: true}`), built at load by each
submodule's own `export-env` via `conn register`:

```nushell
# in mole-sql/mod.nu
use mole/lib/conn.nu
export-env {
  conn register "sql"   # upserts {sql: true} into $env.MOLE_REGISTRY; seeds $env.MOLE_CURRENT
}
```

`conn register` (a `def --env` in `lib/conn.nu`) is the whole mechanism — no
manifest, no file read; a submodule announces just its own driver name. The
registry's keys are the loaded driver names; `conn`'s `--driver` completer
(`driver-names`) reads them. (Connections are resolved from the driver-keyed
config directly — §7 — so resolution itself needs no registry lookup.)

## 6. Submodule contract

A `mole-<tool>` directory must:
1. `use mole/lib/<concern>.nu` for the plumbing it needs (no `*`); annotate completers `@"complete connection"`.
2. Define verbs with clean names (`export def "select"` → `mole-<tool> select`).
3. In `export-env`, call `conn register "<driver>"` to announce its driver name into `$env.MOLE_REGISTRY`.

`mole-sql`/`mole-vlogs` in this workspace are stubs demonstrating the contract.

## 7. Configuration model

Connections at `~/.config/mole/connections.yaml` (honors `$XDG_CONFIG_HOME`),
grouped into a **map keyed by driver** — one section per submodule — so each
section is shape-homogeneous:

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

- Sections are shape-homogeneous (one driver = one connection shape); the section
  key IS the `driver`, so `conn list` flattens the map and tags every record with
  it (no registry lookup needed, no redundant per-record `driver` field).
- **Completion is driver-scoped.** `conn names "<driver>"` returns only that
  driver's connection names. Each submodule wraps it in a tiny local completer
  (`def complete-connection [] { conn names "psql" }`) so its verbs — including
  `set-connection` — never suggest another driver's connections. mole's own
  cross-driver `cfg show` still completes all names (`complete connection`).
- The active connection is **per-driver**: `$env.MOLE_CURRENT = { psql: "prod-pg",
  vlogs: "prod-logs" }`, set by each driver's `set-connection`.
- The old flat `connections:` list is rejected at read with a clear error — group
  connections into driver-keyed sections.
