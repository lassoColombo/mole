# mole — architecture

mole is the shared foundation for a family of small Nushell modules that wrap
data-source CLIs/APIs (`mole-sql`, `mole-vlogs`, …) behind typed, completion-aware
verbs. This document is the interface spec.

## 1. The one principle: submodules depend on mole, never the reverse

```
        ┌──────────────┐
        │     mole     │   mod.nu · cfg.nu · submodules.nu  → user commands
        │  ┌────────┐  │   lib/*.nu                         → plumbing (private)
        │  │  lib   │  │
        └──┴────────┴──┘
              ▲
     ┌────────┼────────┐   each submodule imports the lib CONCERNS it needs
┌────────┐ ┌────────┐ ┌────────┐   (e.g. `use ../mole/lib/conn.nu`)
│mole-sql│ │mole-…  │ │mole-vlg│   and self-registers at load
└────────┘ └────────┘ └────────┘
```

mole **never imports, enumerates, or generates anything about submodules.**
Installing a submodule is only cloning a sibling repo — no umbrella, no
`sync`/codegen. Import rule everywhere: **`use module`, never `use module *`**.

## 2. Constraints that drive the design (verified on 0.114.1)

| Fact | Consequence |
|------|-------------|
| `use X` is a parse keyword; `use $var` is a **parse error**. | Modules can't be discovered/loaded dynamically. The user lists the submodules they want, one `use` line each. |
| **Direct** top-level `use mod` runs its `export-env`; multiple accumulate into `$env`. | Because the user `use`s each submodule directly, their `export-env` blocks run and **self-assemble** `$env.MOLE_REGISTRY`. |
| `use mod` (no `*`) prefixes commands with the module name; a private `use` (not `export use`) does not re-export. | Prefix = dir name (`use mole-sql` → `mole-sql select`). `mod.nu` imports `./lib/*` privately, so `use mole` never leaks plumbing. |
| A file module is imported **with its `.nu` extension** (`use ./lib/conn.nu`); the module name is the basename (`conn`). | Concern files compose as `conn resolve`, `cache path`, … |
| A command's `@"completer"` binding is captured on import. | Callers annotate `@"complete connection"`. |
| `into semver` / `into semver-range` + `in` evaluate semver-ranges (a bare version means caret); `into semver` rejects non-semver and `v`-prefixed strings. | Version gating and tag validation are native one-liners — no dependency. |

## 3. Layout & command surface

```
<workspace>/
├── mole/
│   ├── mod.nu          # composition + `mole api-version`, `mole edit`
│   ├── cfg.nu          # `mole cfg show/file/querydir/edit`
│   ├── submodules.nu   # `mole submodules sources/doctor/install/uninstall/update/checkout`
│   ├── mole.nuon       # mole's single tag: { api } (read at runtime)
│   └── lib/            # plumbing concerns (private to mole; imported by submodules)
│       ├── version.nu · config.nu · conn.nu · cache.nu · query.nu · complete.nu
├── mole-sql/    mod.nu · plugin.nuon      (`use ../mole/lib/*.nu`)
└── mole-vlogs/  mod.nu · plugin.nuon
```

`use mole` exposes **only management commands** (scoped where natural):
`mole api-version`, `mole edit`, `mole cfg …`, `mole submodules …`. `mod.nu`
composes `cfg.nu`/`submodules.nu` with `export use ./cfg.nu` / `export use
./submodules.nu` (whole-file, no `*`), so their leaf defs become `mole cfg show`,
`mole submodules sources`, etc.

## 4. The lib (plumbing), imported per concern

Each concern is a file under `lib/`, imported individually with its `.nu`
extension. Submodules import only what they need; `use mole` never exposes any:

| Import | Commands |
|--------|----------|
| `use ../mole/lib/version.nu` | `version api-version`, `version require-api` |
| `use ../mole/lib/config.nu`  | `config file`, `config querydir` |
| `use ../mole/lib/conn.nu`    | `conn list`, `conn resolve`, `conn override` |
| `use ../mole/lib/cache.nu`   | `cache path/read/write/stale/clear` |
| `use ../mole/lib/query.nu`   | `query resolve`, `query confirm`, `query check` |
| `use ../mole/lib/complete.nu`| `complete connection`, `complete queryfile` |

Core ships *mechanism*; each submodule owns *policy* (what's dangerous, how to
type results, how to exec).

## 5. The self-assembling registry — `$env.MOLE_REGISTRY`

A record keyed by source, built at load by each submodule's own `export-env`:

```nushell
# in mole-sql/mod.nu
use ../mole/lib/version.nu
use ../mole/lib/conn.nu
const HERE = (path self | path dirname)
export-env {
  let m = (open ([$HERE plugin.nuon] | path join))   # its manifest (data)
  version require-api $m.api                           # version gate (§6)
  $env.MOLE_REGISTRY = (($env.MOLE_REGISTRY? | default {}) | upsert $m.source $m)
  $env.MOLE_CURRENT  = ($env.MOLE_CURRENT? | default {})
}
```

`conn list` reads the registry to map a connection's `driver` → owning `source`;
`mole submodules sources/doctor` read it to know what's loaded.

## 6. Versioned integration

- **mole core declares exactly one version: `api`**, in `mole.nuon` (currently
  `0.1.0`), read at runtime by `version api-version`. It is the core↔submodule
  contract version — the single number every requirement is checked against.
- Each submodule declares THREE requirement kinds, all native semver-ranges:
  `api` (range on core; `*` = free, for a pure library that imports nothing from
  core), `deps` (`[{module, version}]`, range per module dependency) and
  `requires` (`[{name, version}]`, range per external CLI it drives). `version`
  is the submodule's own release.
- At load, a submodule calls `version require-api $m.api`, which errors unless
  `(api-version | into semver) in ($m.api | into semver-range)`. The declared
  range is honored as written — a bare version means caret, and `^`/`~`/`>=`/`=`,
  a comma-compound (`>=1.0.0, <2.0.0`) or `*` all work.
- `mole submodules doctor` checks all three per *installed* submodule: the core
  api range, each dep's range, and each required CLI's `--version` against its
  range (probed by running `<cli> --version`).

## 7. Submodule management (`mole submodules …`)

| Command | Purpose |
|---------|---------|
| `sources` | Installed submodules (from `<workspace>/mole-*/plugin.nuon`) + `loaded`/`ready`. |
| `doctor`  | api + dep + CLI-version range checks. |
| `install <name> <url>` | `git clone` a `mole-*` submodule as a sibling. |
| `uninstall <name>` | Remove its sibling dir (completes installed names). |
| `update <name>` | `git pull --ff-only` (completes installed names). |
| `checkout <name> <tag>` | `git checkout` at a release **tag**. Tags are native semver, **no `v` prefix**; `<tag>` completion lists the submodule's valid semver tags, latest first, and the value is validated with `into semver`. |

Discovery/install operate on `<workspace>/mole-*/` — never on anything inside
mole. `submodules.nu` self-locates via `const WORKSPACE = (path self | path
dirname | path dirname)`.

## 8. Submodule contract

A `mole-<tool>` directory must:
1. Ship `plugin.nuon`: `{ source, version, api, deps?, requires?, drivers?, family?, suffix?, summary }` — `api`/`deps`/`requires` are the three semver-range requirements (§6); `requires` is `[{name, version}]`, `deps` is `[{module, version}]`.
2. `use ../mole/lib/<concern>.nu` for the plumbing it needs (no `*`); annotate completers `@"complete connection"`.
3. Define verbs with clean names (`export def "select"` → `mole-<tool> select`).
4. In `export-env`, call `version require-api $m.api` and upsert its manifest into `$env.MOLE_REGISTRY`.

`mole-sql`/`mole-vlogs` in this workspace are stubs demonstrating the contract.

## 9. Configuration model

Flat, driver-keyed connections at `~/.config/mole/connections.yaml` (honors
`$XDG_CONFIG_HOME`):

```yaml
connections:
  - name: prod-pg
    driver: postgres        # driver → source resolved via $env.MOLE_REGISTRY
    host: db.example.com
    port: 5432
    user: alice
    password: hunter2
    database: app
  - name: prod-logs
    driver: victorialogs
    url: https://vl.example.com
```

- Records are heterogeneous; each submodule reads the fields it needs.
- The active connection is **per-source**: `$env.MOLE_CURRENT = { sql: "prod-pg",
  vlogs: "prod-logs" }`, set by each source's `set-connection`.
- Legacy sectioned configs are converted once with `migrate-connections.nu`.
