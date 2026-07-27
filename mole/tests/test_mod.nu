use std/assert
use std/testing *

use ../mod.nu

# Management commands MUST be exposed by `use ../mod.nu`.
@test
def "management commands are present" [] {
  let names = (scope commands | get name)
  for cmd in ["mod cfg show" "mod query show" "mod query dir"] {
    assert ($cmd in $names) $"expected command not exposed: ($cmd)"
  }
}

# `query show` returns the raw text of a saved query, resolved against the
# query dir (XDG-aware).
@test
def "query show returns saved query text" [] {
  let temp = mktemp --tmpdir --directory
  mkdir ([$temp mole queries] | path join)
  "SELECT 1" | save ([$temp mole queries hello.sql] | path join)
  $env.XDG_CONFIG_HOME = $temp
  let out = (mod query show "hello.sql")
  rm --recursive $temp
  assert equal $out "SELECT 1"
}

# Architectural guard: `use mole` must NEVER leak plumbing. No exposed command's
# leaf may be a plumbing concern (conn/cache/config/version). `query` is special:
# it is ALSO the user-facing query-management namespace (`query edit`, `query
# show`, `query dir`, …), so for that leaf we forbid only the lib/query.nu
# plumbing verbs — an `export use ./lib/query.nu` leak would surface `query
# resolve`/`confirm`/`check` — while allowing the hand-written management verbs.
@test
def "plumbing is not leaked" [] {
  let mod_cmds = (scope commands | get name | where ($it | str starts-with "mod "))
  let plumbing = ["conn" "cache" "config"]
  let query_plumbing = ["resolve" "confirm" "check"]
  for cmd in $mod_cmds {
    let parts = ($cmd | str replace "mod " "" | split row " ")
    let leaf = ($parts | first)
    assert ($leaf not-in $plumbing) $"plumbing leaked via: ($cmd)"
    if $leaf == "query" {
      let sub = ($parts | get -o 1 | default "")
      assert ($sub not-in $query_plumbing) $"plumbing leaked via: ($cmd)"
    }
  }
}
