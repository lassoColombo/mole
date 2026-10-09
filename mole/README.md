# mole

A Nushell framework to manage and query heterogeneous data sources.

---

`mole` is the shared foundation for a family of small Nushell modules that wrap
data-source CLIs/APIs behind typed, completion-aware verbs. It provides
connection config, query/cache/editor plumbing, and the contextual completion
toolkit every driver builds on.

**One principle: dependencies point one way.** Drivers depend on pure libraries
and on mole core; core never imports or enumerates drivers, so installing one is
cloning it next to `mole/` and adding a `use` line. See [`DESIGN.md`](DESIGN.md).

## Layout

```
<workspace>/                  # the dir on $env.NU_LIB_DIRS
├── mole/                     # core: `mole cfg …`, `mole query …`, lib/ plumbing
│   ├── mod.nu · cfg.nu
│   └── lib/                  # config · conn · cache · query · editor · complete
├── mole-sql/sql.nu           # pure SQL library (assemble, predicate tokens, schema cache helpers, where-plan)
├── mole-myql/myql.nu         # pure MySQL-dialect library (shared by mole-mysql / mole-mariadb)
├── mole-promql/promql.nu     # pure PromQL library (shared by mole-prometheus / mole-victoriametrics)
├── mole-psql/ mole-mysql/ mole-mariadb/ mole-trino/ mole-duckdb/     # SQL drivers
├── mole-mongodb/ mole-victorialogs/ mole-prometheus/ mole-victoriametrics/
├── mole-mermaid/ mole-sqls/ mole-zellij/                             # tools over core
└── run-tests.nu              # every module's nutest suite
```

## How it fits together

- **The user `use`s each module directly** (one `use` line each, never `*`):
  `use mole`, `use mole-psql`, … Commands are prefixed by the module name →
  `mole cfg show`, `mole-psql select`.
- **`use mole` exposes only management commands**; the plumbing in `mole/lib/` is
  imported privately by `mod.nu` and never leaks. Drivers import the lib concerns
  they need directly (`use mole/lib/conn.nu` → `conn resolve`).
- **Registry self-assembles.** Each driver's `export-env` calls
  `conn register "<driver>"`; loading several accumulates them. No manifest.
- **Pure libraries stay pure.** `mole-sql` and friends do no I/O; dialect specifics
  are injected, and where a driver would copy orchestration the library returns a
  *plan* the driver executes (`sql where-plan`).

## Try it

```nushell
$env.NU_LIB_DIRS ++= ["/abs/path/to/workspace"]   # the dir CONTAINING mole/, mole-psql/, …

use mole
use mole-psql

mole cfg show                                   # configured connections (secrets masked), by driver
mole-psql set-connection prod-pg
mole-psql select id email --from users --where status=active,age>=30 --sort-by id --limit 5
mole-psql select --from users --where "created_at > now() - interval '1 day'" --dry-run
mole-psql schema --table users
```

Config lives at `~/.config/mole/connections.yaml` (a map **keyed by driver**;
honors `$XDG_CONFIG_HOME`). Connection names are unique across drivers.

## Tests

```nushell
nu run-tests.nu                 # all suites (needs the workspace + nutest's parent on NU_LIB_DIRS)
nu run-tests.nu --path mole-sql
```
