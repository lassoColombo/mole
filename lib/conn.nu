# mole/lib/conn — connection reading, resolution, overrides.
# Import individually: `use ../mole/lib/conn` → `conn list`, `conn resolve`, `conn override`.
#
# Connections live in ~/.config/mole/connections.yaml under a `connections:` map
# KEYED BY SOURCE (one section per submodule: `psql:`, `mysql:`, `vlogs:`, …), so
# each section is shape-homogeneous. A connection's `source` is the section it is
# filed under; `list` flattens the sections and tags each record with it. An
# optional per-record `driver` distinguishes engines within a source (postgres vs
# timescaledb) but nothing here branches on it.

use ./config.nu

# Raw connections, flattened from the source-keyed `connections:` map.
#
# Reads the config file and expands its `{ <source>: [<record>...] }` sections
# into a flat list, tagging every record with the `source` it was filed under.
# Returns [] when the file does not exist. Errors when the file has no
# `connections:` key, or when it is still the OLD flat list (group by source
# first — a scratch migration converts it).
@category mole-lib
@example "read the raw connection list" { read-connections }
def read-connections []: nothing -> list {
  let f = config file
  if not ($f | path exists) { return [] }
  let raw = open $f
  if ("connections" not-in ($raw | columns)) {
    error make {msg: $"($f) has no `connections:` map — expected connections grouped by source"}
  }
  let conns = ($raw.connections | default {})
  if (($conns | describe) | str starts-with "list") {
    error make {msg: $"($f): the flat `connections:` list is no longer supported — group connections by source, e.g. `connections: {psql: [...], vlogs: [...]}`"}
  }
  $conns | items {|source, rows| ($rows | default []) | each {|c| $c | insert source $source } } | flatten
}

# Completer: source names, from the self-assembled registry.
#
# Local (not from lib/complete) on purpose: `complete` imports this module, so
# importing it back would be a circular dependency. The names come straight from
# the registry keys of loaded submodules.
@category mole-lib
@example "source-name suggestions" { source-names }
def source-names []: nothing -> list<string> {
  $env.MOLE_REGISTRY? | default {} | columns
}

# All connections, each tagged with its `source` (the section it is filed under).
@category mole-lib
@example "list connections with their sources" { list }
export def "list" []: nothing -> table {
  read-connections
}

# Connection names owned by a source, for source-scoped completion.
#
# Returns just the names of connections filed under `source`. Submodules wrap this
# in a tiny local completer (`def complete-connection [] { conn names "psql" }`)
# so a source's verbs only ever suggest that source's own connections.
@category mole-lib
@example "names of the psql connections" { names "psql" }
export def "names" [
  source: string   # The source whose connection names to list
]: nothing -> list<string> {
  list | where source == $source | get -o name | default []
}

# Resolve a single connection record, secrets intact, for running a query.
#
# With a `name`, resolves that connection (errors if unknown). Otherwise, with
# `--source`, resolves the current connection for that source (from
# `$env.MOLE_CURRENT`). When `--source` is given it also asserts the resolved
# connection actually belongs to that source. Errors if neither a name nor a
# source is given.
@category mole-lib
@example "resolve a connection by name" { resolve prod-db }
@example "resolve the current connection for a source" { resolve --source sql }
export def "resolve" [
  name?: string      # Connection name to resolve; omit to use the current-for-`--source`
  --source: string@source-names   # Source to resolve the current connection for, and to assert membership against
]: nothing -> record {
  let all = list
  let conf = if ($name | is-not-empty) {
    let hit = $all | where name == $name
    if ($hit | is-empty) { error make {msg: $"unknown connection: ($name)"} }
    $hit | first
  } else if ($source | is-not-empty) {
    let cur = ($env.MOLE_CURRENT? | default {}) | get -o $source
    if ($cur | is-empty) {
      error make {msg: $"no current ($source) connection — pass a name or set one via `($source) set-connection`"}
    }
    $all | where name == $cur | first
  } else {
    error make {msg: "specify a connection name or a --source"}
  }
  if ($source | is-not-empty) and ($conf.source != $source) {
    error make {msg: $"connection '($conf.name)' is a '($conf.source | default '?')' connection, not '($source)'"}
  }
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
# here. `name` picks the connection (else the current-for-`source`); null-valued
# overrides are dropped, so unset flags are no-ops.
@category mole-lib
@example "a named sql connection with an overridden port" {
  with sql "prod-db" {port: 6543}
}
export def "with" [
  source: string@source-names   # Source to resolve the current connection for when no name is given
  name?: string         # Connection name; omit to use the current-for-`source`
  overrides: record = {}  # Fields to override; null-valued fields are skipped
]: nothing -> record {
  resolve $name --source $source | override $overrides
}
