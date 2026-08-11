# mole/lib/conn — connection reading, resolution, overrides.
# Import individually: `use mole/lib/conn` → `conn list`, `conn resolve`, `conn override`.
#
# Connections live in ~/.config/mole/connections.yaml under a `connections:` map
# KEYED BY DRIVER (one section per submodule: `psql:`, `mysql:`, `vlogs:`, …), so
# each section is shape-homogeneous. A connection's `driver` is the section it is
# filed under; `list` flattens the sections and tags each record with it.

use ./config.nu
use ./cache.nu

# Raw connections, flattened from the driver-keyed `connections:` map.
#
# Reads the config file and expands its `{ <driver>: [<record>...] }` sections
# into a flat list, tagging every record with the `driver` it was filed under (the
# section key is authoritative, so a stray per-record `driver` is overwritten).
# Returns [] when the file does not exist. Errors when the file has no
# `connections:` key, or when it is still the OLD flat list (group by driver
# first — a scratch migration converts it).
@category mole-lib
@example "read the raw connection list" { read-connections }
def read-connections []: nothing -> list {
  let f = config file
  if not ($f | path exists) { return [] }
  let raw = open $f
  if ("connections" not-in ($raw | columns)) {
    error make {msg: $"($f) has no `connections:` map — expected connections grouped by driver"}
  }
  let conns = ($raw.connections | default {})
  if (($conns | describe) | str starts-with "list") {
    error make {msg: $"($f): the flat `connections:` list is no longer supported — group connections by driver, e.g. `connections: {psql: [...], vlogs: [...]}`"}
  }
  $conns | items {|driver, rows| ($rows | default []) | each {|c| $c | upsert driver $driver } } | flatten
}

# Register a loaded driver into the session registry.
#
# Called from each submodule's `export-env` so `--driver` completion
# (`driver-names`) can suggest it. The registry is a set of loaded driver names
# ({<driver>: true}); entries accumulate across submodules, so a driver only
# needs to announce its own name — no manifest, no file read. Also seeds
# `$env.MOLE_CURRENT` so `set-connection` / `resolve --driver` have a map to
# upsert into. Idempotent.
@category mole-lib
@example "register this submodule's driver" { register "psql" }
export def --env "register" [
  driver: string   # The driver name this submodule provides
]: nothing -> nothing {
  $env.MOLE_REGISTRY = (($env.MOLE_REGISTRY? | default {}) | upsert $driver true)
  $env.MOLE_CURRENT = ($env.MOLE_CURRENT? | default {})
}

# Completer: driver names, from the self-assembled registry.
#
# Local (not from lib/complete) on purpose: `complete` imports this module, so
# importing it back would be a circular dependency. The names come straight from
# the registry keys of loaded submodules.
@category mole-lib
@example "driver-name suggestions" { driver-names }
def driver-names []: nothing -> list<string> {
  $env.MOLE_REGISTRY? | default {} | columns
}

# All connections, each tagged with its `driver` (the section it is filed under).
@category mole-lib
@example "list connections with their drivers" { list }
export def "list" []: nothing -> table {
  read-connections
}

# Connection names owned by a driver, for driver-scoped completion.
#
# Returns just the names of connections filed under `driver`. Submodules wrap this
# in a tiny local completer (`def complete-connection [] { conn names "psql" }`)
# so a driver's verbs only ever suggest that driver's own connections.
@category mole-lib
@example "names of the psql connections" { names "psql" }
export def "names" [
  driver: string   # The driver whose connection names to list
]: nothing -> list<string> {
  list | where driver == $driver | get -o name | default []
}

# Resolve a single connection record, secrets intact, for running a query.
#
# With a `name`, resolves that connection (errors if unknown). Otherwise, with
# `--driver`, resolves the current connection for that driver (from
# `$env.MOLE_CURRENT`). When `--driver` is given it also asserts the resolved
# connection actually belongs to that driver. Errors if neither a name nor a
# driver is given.
@category mole-lib
@example "resolve a connection by name" { resolve prod-db }
@example "resolve the current connection for a driver" { resolve --driver sql }
export def "resolve" [
  name?: string      # Connection name to resolve; omit to use the current-for-`--driver`
  --driver: string@driver-names   # Driver to resolve the current connection for, and to assert membership against
]: nothing -> record {
  let all = list
  let conf = if ($name | is-not-empty) {
    let hit = $all | where name == $name
    if ($hit | is-empty) { error make {msg: $"unknown connection: ($name)"} }
    $hit | first
  } else if ($driver | is-not-empty) {
    let cur = ($env.MOLE_CURRENT? | default {}) | get -o $driver
    if ($cur | is-empty) {
      error make {msg: $"no current ($driver) connection — pass a name or set one via `($driver) set-connection`"}
    }
    $all | where name == $cur | first
  } else {
    error make {msg: "specify a connection name or a --driver"}
  }
  if ($driver | is-not-empty) and ($conf.driver != $driver) {
    error make {msg: $"connection '($conf.name)' is a '($conf.driver | default '?')' connection, not '($driver)'"}
  }
  $conf
}

# Make `name` the current connection for `driver`, in `$env.MOLE_CURRENT`.
#
# Validates that `name` exists and is actually a `driver` connection — it resolves
# through `resolve $name --driver $driver`, which errors on an unknown name or a
# cross-driver mismatch — then upserts `$env.MOLE_CURRENT.<driver> = name`, so later
# verbs can `resolve --driver <driver>` and the user can omit `--connection`. Being
# `--env`, the change persists in the caller's environment: a submodule's own
# `set-connection` verb is a thin `--env` wrapper over this. RETURNS the resolved
# connection record, so a driver that warms a cache on switch can chain off it
# (`let conf = (conn set-current "vlogs" $name)`); a driver that doesn't need it
# pipes the record to `ignore` (env changes still propagate through the pipe).
@category mole-lib
@example "make a psql connection the current one" { set-current "psql" "prod-db" }
export def --env "set-current" [
  driver: string   # The driver the connection belongs to (membership asserted via `resolve`)
  name: string     # The connection name to make current
]: nothing -> record {
  let conf = (resolve $name --driver $driver)
  $env.MOLE_CURRENT = (($env.MOLE_CURRENT? | default {}) | upsert $driver $name)
  # Mirror the choice into a cache file so completion can resolve the current
  # connection even when it can't see the session $env (completers usually can't).
  try { {name: $name} | cache write (cache path $driver "__current__") } catch { }
  $conf
}

# Apply non-null overrides to a piped connection record.
#
# Fields in `overrides` whose value is null are ignored; the rest are upserted
# onto the piped base record. Useful for applying command-line `--host`/`--port`
# flags over a resolved connection.
@category mole-lib
@example "override the port, ignoring null fields" {
  {host: "db", port: 5432} | override {port: 6543, user: null}
} --result {host: "db", port: 6543}
export def "override" [
  overrides: record   # Fields to apply; null-valued fields are skipped
]: record -> record {
  let base = $in
  $overrides
  | items {|k, v| {k: $k, v: $v} }
  | where v != null
  | reduce --fold $base {|it, acc| $acc | upsert $it.k $it.v }
}

# Resolve a connection then apply overrides — the one-call `resolve` + `override`.
#
# The blessed override path every driver shares: a verb collects its
# `--host`/`--port`/… flags (plus a generic `--set`) into a record and passes it
# here. `name` picks the connection (else the current-for-`driver`); null-valued
# overrides are dropped, so unset flags are no-ops.
@category mole-lib
@example "a named sql connection with an overridden port" {
  with sql "prod-db" {port: 6543}
}
export def "with" [
  driver: string@driver-names   # Driver to resolve the current connection for when no name is given
  name?: string         # Connection name; omit to use the current-for-`driver`
  overrides: record = {}  # Fields to override; null-valued fields are skipped
]: nothing -> record {
  resolve $name --driver $driver | override $overrides
}

# Drop secret-looking fields from a connection record, for safe display.
#
# Driver-agnostic field-name heuristic: any column whose name matches
# `pass`/`token`/`secret` (case-insensitive) is removed; everything else is kept.
# Empty input passes through. Used by dry-run output and `mole cfg show` so a
# resolved connection can be shown without leaking its credentials.
@category mole-lib
@example "redact secrets from a connection record" {
  {host: "db", password: "hunter2", token: "x"} | redact
} --result {host: "db"}
export def "redact" []: any -> any {
  let c = $in
  if ($c | is-empty) { return $c }
  let secret = ($c | columns | where {|k| $k =~ '(?i)pass|token|secret' })
  if ($secret | is-empty) { $c } else { $c | reject ...$secret }
}
