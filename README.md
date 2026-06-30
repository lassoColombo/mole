# mole

A [Nushell](https://www.nushell.sh/) module for running SQL queries against named connections.

Define your MySQL/PostgreSQL connections in `~/.config/mole.yml`, point at one, and get the result back as a Nushell table.

## Why

`mysql` and `psql` CLIs are fine, but jumping between them, remembering host/port/credentials, and re-parsing their output every time gets old fast. `mole` is one verb (`mole -q "..." -c connection`) that picks the right driver based on the connection's config, runs the query, and hands back structured data the rest of your pipeline can use.

## Requirements

| Tool | Purpose |
|------|---------|
| [Nushell](https://www.nushell.sh/) | Host shell |
| [`mysql`](https://dev.mysql.com/doc/refman/en/mysql.html) | CLI used by the `mysql` driver |
| [`psql`](https://www.postgresql.org/docs/current/app-psql.html) | CLI used by the `postgres` driver |
| [`mongosh`](https://www.mongodb.com/docs/mongodb-shell/) | CLI used by the `mongo` driver |
| [`redis-cli`](https://redis.io/docs/latest/develop/connect/cli/) | CLI used by the `redis` driver |
| [`valkey-cli`](https://valkey.io/) | CLI used by the `valkey` driver (RESP-compatible) |

You only need the CLI(s) for the drivers you actually use.

## Installation

```nushell
# clone into one of your NU_LIB_DIRS
let dest = [($env.NU_LIB_DIRS | first) mole] | path join
git clone git@github.com:lassoColombo/mole.git $dest

# use the module
use mole
mole --help
```

## Configuration

Connections live in `~/.config/mole.yml` as a list of records, each with a `name` field plus the driver's expected fields. List order is preserved — it shows up in `mole cfg show`, in `translate-to` output, and in any `cfg show | to yaml` round-trip. `database` is optional — omit it for server-level connections (handy for `SHOW DATABASES`, cross-db queries, or queries that name databases explicitly).

```yaml
sql:
  - name: my-postgres
    driver: postgres
    user: alice
    password: hunter2
    host: db.example.com
    port: 5432
    database: app_production

  - name: my-mysql
    driver: mysql
    user: alice
    password: hunter2
    host: mysql.example.com
    port: 3306
    database: app

mongo:
  - name: my-mongo
    user: alice
    password: hunter2
    host: mongo.example.com
    port: 27017
    database: app

redis:
  - name: my-redis
    driver: redis          # or `valkey` — any RESP-compatible CLI
    user: default          # optional — ACL user (omit to skip)
    password: hunter2      # optional
    host: redis.example.com
    port: 6379
    database: "0"          # optional — db index (0..N-1)

  - name: my-valkey
    driver: valkey         # uses valkey-cli instead of redis-cli
    password: hunter2
    host: valkey.example.com
    port: 6379
```

Query files live under `~/.config/mole/` (recursively); reference them with `-f path/to/query.sql`.

## Quick start

```nushell
# run an inline query against a named connection
mole -c my-postgres -q 'select 1 as one'

# run a saved query file (path relative to ~/.config/mole/)
mole -c my-postgres -f reports/active-users.sql

# no -q and no -f opens $env.EDITOR on a temp file; runs whatever you save
mole -c my-postgres

# pick a default connection — subsequent bare calls use it
mole cfg set my-postgres
mole -q 'select now()'

# override fields ad-hoc without editing mole.yml
mole -c my-postgres -d app_staging -q 'select count(*) from users'

# write a destructive query? you'll get a yellow prompt unless you pass -y
mole -c my-postgres -q 'delete from sessions where expires_at < now()' -y
```

## Commands

| Command | Purpose |
|---------|---------|
| `mole` | Run a SQL query. Returns a table. |
| `mole edit [queryfile]` | Open the query directory (or one file) in `$env.EDITOR`. |
| `mole cfg show [name]` | Show all connections, or just one. Passwords masked unless `-r`. |
| `mole cfg edit` | Open `~/.config/mole.yml` in `$env.EDITOR`. |
| `mole cfg set [name]` | Set the default connection. Picks interactively if no name given. |
| `mole cfg translate-to <spec>` | Render the connection list as config for another tool. See [Translate-to](#translate-to). |

### `mole` flags

| Flag | Short | Description |
|------|-------|-------------|
| `--query` | `-q` | Inline SQL |
| `--file` | `-f` | Query file relative to `~/.config/mole/` |
| `--connection` | `-c` | Named connection from `mole.yml` |
| `--driver` | `-D` | Override the driver (`mysql` or `postgres`) |
| `--database` | `-d` | Override the database |
| `--port` | `-p` | Override the port |
| `--user` | `-u` | Override the user |
| `--host` | `-h` | Override the host |
| `--password` | `-P` | Override the password |
| `--yes` | `-y` | Skip the dangerous-query prompt |

If `--query` and `--file` are both omitted, `mole` opens `$env.EDITOR` on a temp `.sql` file and runs whatever you save.

## Drivers

The driver map lives in `drivers.nu`. Each entry declares everything that varies per driver:

| Field | Purpose |
|-------|---------|
| `dangerous_keywords` | Regex matched against the query to trigger the danger prompt |
| `exec` | Closure that runs the query and returns a `complete` record |
| `parse` | Closure that turns stdout into a table |
| `list_databases` / `db_column` / `db_parser` | Powers the `--database` completer |

Built-in drivers:

| Driver | CLI used | Output parsed as |
|--------|----------|------------------|
| `mysql` | `mysql` | TSV |
| `postgres` | `psql --csv` | CSV |
| `mongo` | `mongosh --json=canonical` | EJSON |
| `redis` | `redis-cli --json` | JSON per line (raw fallback) |
| `valkey` | `valkey-cli --json` | JSON per line (raw fallback) |

Adding a driver is a matter of adding one entry to the registry in `drivers.nu`. The pipeline in `mod.nu` dispatches through the registry — no command code changes needed.

## Schema

`mole` caches each SQL connection's schema (tables, columns, constraints) under `~/.cache/mole/` and refreshes it in the background after queries. Two commands read that cache; both live in `schema.nu`.

### `mole sql schema`

Inspect the cached schema as Nushell data.

| Flag | Short | Description |
|------|-------|-------------|
| `--connection` | `-c` | Named connection (default: current) |
| `--table` | `-t` | Detailed record `{schema, name, columns, constraints}` for one table (`table` or `schema.table`) |
| `--find` | | Tables/columns whose name or comment matches (case-insensitive) |
| `--refresh` | `-r` | Rebuild the cache before reading |
| `--full` | | Return the entire cache record |

```nushell
mole sql schema                       # one summary row per table
mole sql schema -t orders             # columns + constraints for `orders`
mole sql schema --find email          # where does "email" show up?
mole sql schema -r                    # force a refresh first
```

### `mole sql dumpschema`

Serialize the cached schema to a diagram/text format. The result is a string, so redirect or pipe it where you need it.

| Flag | Short | Description |
|------|-------|-------------|
| `--connection` | `-c` | Named connection (default: current) |
| `--format` | `-F` | Output format (default: `mermaid`) |
| `--refresh` | `-r` | Rebuild the cache before dumping |

```nushell
mole sql dumpschema | save schema.mmd
mole sql dumpschema -c my-pg --format mermaid
```

The `mermaid` format renders a [Mermaid](https://mermaid.js.org/) `erDiagram`: one entity per table with its columns (type plus `PK`/`FK`/`UK` markers and comments) and one relationship per foreign key — the relationship cardinality reflects whether the FK is mandatory (`||`) or nullable (`|o`).

Like the driver registry, formats are pluggable: add an entry to the `dump-formatters` record in `schema.nu` and the `--format` flag, its completer, and the dispatch all pick it up — no command changes needed.

## Translate-to

`mole cfg translate-to <spec>` returns a structured record matching the target tool's config schema. The user picks the encoding:

```nushell
mole cfg translate-to sqls | to yaml | save -f ~/.config/sqls/config.yml
```

Supported specs:

| Spec | Target |
|------|--------|
| `sqls` | [`sqls`](https://github.com/sqls-server/sqls) language server (`config.yml`) |

## Dangerous-query prompt

Each driver carries a regex of statements that warrant a confirmation prompt — `delete`, `drop`, `truncate`, `vacuum`, `flush`, etc. The regex is driver-specific (postgres has `vacuum` and `reindex`; mysql has `flush` and `kill`). Pass `-y` to skip.

## Module structure

```
mole/
├── mod.nu          # query runners (`sql run`/`sql select`, `mongo`, `redis`), `edit`, re-exports cfg + schema
├── cfg.nu          # connection-file management, `cfg` commands, translate-to
├── schema.nu       # `sql schema` (views) + `sql dumpschema` (mermaid & future formats)
├── drivers.nu      # per-driver registry (exec / parse / danger keywords / schema queries)
├── cache.nu        # per-(connection, database) schema cache
├── types.nu        # cached-type → native-value conversion for `sql select`
├── completers.nu   # tab completers
└── ejson.nu        # MongoDB Extended JSON decoding
```
