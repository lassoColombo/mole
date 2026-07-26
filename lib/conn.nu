# mole/lib/conn — connection reading, resolution, overrides.
# Import individually: `use ../mole/lib/conn` → `conn list`, `conn resolve`, `conn override`.
#
# Connections are a flat, driver-keyed list in ~/.config/mole/connections.yaml.
# A connection's `source` is derived from its `driver` via $env.MOLE_REGISTRY
# (self-assembled by loaded submodules), so nothing here knows any source name.

use ./config.nu

# Raw connection list from the flat `connections:` form of the config file.
#
# Returns an empty list when the config file does not exist; errors when the file
# exists but has no `connections:` key (the legacy sectioned form is not read at
# runtime — convert it once with migrate-connections.nu).
@category mole-lib
@example "read the raw connection list" { read-connections }
def read-connections []: nothing -> list {
  let f = config file
  if not ($f | path exists) { return [] }
  let raw = open $f
  if ("connections" not-in ($raw | columns)) {
    error make {msg: $"($f) has no `connections:` list — if it's an old sectioned config, run migrate-connections.nu first"}
  }
  $raw.connections
}

# The source that owns a driver, per the self-assembled registry.
#
# Looks the driver up across every loaded submodule's declared `drivers` in
# `$env.MOLE_REGISTRY`. Returns the owning source name, or null if no loaded
# submodule claims the driver.
@category mole-lib
@example "which source owns the postgres driver" { driver-source "postgres" }
def driver-source [
  driver: string   # The connection driver name to look up
]: nothing -> any {
  ($env.MOLE_REGISTRY? | default {})
  | items {|name, m| {name: $name, drivers: ($m | get -o drivers | default [])} }
  | where {|e| $driver in $e.drivers }
  | get -o 0.name
}

# Completer: loaded source names, from the self-assembled registry.
#
# Local (not from lib/complete) on purpose: `complete` imports this module, so
# importing it back would be a circular dependency. The names come straight from
# the registry keys this module already reads.
@category mole-lib
@example "source-name suggestions" { source-names }
def source-names []: nothing -> list<string> {
  $env.MOLE_REGISTRY? | default {} | columns
}

# All connections, each tagged with its resolved `source`.
#
# Reads the config file and adds a `source` column to every connection by
# resolving its `driver` through the registry (null when unclaimed).
@category mole-lib
@example "list connections with resolved sources" { list }
export def "list" []: nothing -> table {
  read-connections | each {|c| $c | insert source (driver-source ($c | get -o driver | default "")) }
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
