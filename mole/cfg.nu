# mole/cfg.nu — connection-config commands. Composed by mod.nu as `mole cfg …`.
# Leaf def names (`show`, `file`, …); mod.nu's `export use ./cfg.nu` prefixes
# them with `cfg`, and `use mole` adds `mole`.

use ./lib/conn.nu
use ./lib/config.nu
use ./lib/complete.nu

# Drop secret-looking fields from a piped connection record/table.
#
# Driver-agnostic field-name heuristic: any column whose name matches
# `pass`/`token`/`secret` (case-insensitive) is rejected. A truthy `raw` (or
# empty input) passes the value through untouched.
@example "mask a connection record" { {host: "db", password: "hunter2"} | mask false } --result {host: "db"}
@example "raw passes everything through" { {host: "db", password: "hunter2"} | mask true } --result {host: "db", password: "hunter2"}
def mask [
  raw: bool   # When true, return the input unchanged (no masking)
]: any -> any {
  let c = $in
  if ($c | is-empty) or $raw { return $c }
  $c | conn redact
}

# Show configured connections, with secret-looking fields masked.
#
# With no name, returns a record keyed by driver (`{psql: <table>, vlogs:
# <table>, …}`) so each section stays shape-homogeneous. With a name, returns that
# single connection record (or null if it does not exist), searched across all
# drivers. Password/token/secret fields are hidden unless `--raw` is given.
@category mole
@example "list all connections, grouped by driver (secrets masked)" { mole cfg show }
@example "show one connection" { mole cfg show prod-db }
@example "show one connection with secrets" { mole cfg show prod-db --raw }
export def "show" [
  name?: string@"complete connection"   # Connection name to show; omit for all, grouped by driver
  --raw(-r)                             # Reveal secret-looking fields (password/token/secret) instead of masking
] {
  if ($name | is-not-empty) {
    return (conn list | where name == $name | first | default null | mask $raw)
  }
  conn list
  | group-by driver
  | items {|driver, rows| {key: $driver, val: ($rows | each {|c| $c | reject driver | mask $raw})} }
  | reduce --fold {} {|it, acc| $acc | upsert $it.key $it.val }
}

# Absolute path to the connections file (~/.config/mole/connections.yaml).
@category mole
@example "print the connections file path" { mole cfg file }
export def "file" []: nothing -> string { config file }

@category mole
@example "print the config directory path" { mole cfg dir }
export def "dir" []: nothing -> string { config dir }

# Open the connections file in $EDITOR.
@category mole
@example "edit the connections file" { mole cfg edit }
export def "edit" []: nothing -> nothing { nu -c $"($env.EDITOR) (config file)" }
