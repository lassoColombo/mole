use std/assert
use std/testing *

use ../mod.nu

# Absolute path to the manifest, resolved at parse time relative to this file.
const MANIFEST = (path self ../mole.nuon)

# The api version reported by `mod api-version` must equal the `api` field
# in the manifest (mole.nuon), the single source of truth.
@test
def "api-version matches manifest" [] {
  let manifest_api = (open $MANIFEST | get api)
  assert equal (mod api-version) $manifest_api
}

# Management commands MUST be exposed by `use ../mod.nu`.
@test
def "management commands are present" [] {
  let names = (scope commands | get name)
  for cmd in ["mod api-version" "mod cfg show" "mod submodules sources"] {
    assert ($cmd in $names) $"expected command not exposed: ($cmd)"
  }
}

# Architectural guard: `use mole` must NEVER leak plumbing. No exposed command's
# leaf may be a plumbing concern (conn/cache/query/config/version).
@test
def "plumbing is not leaked" [] {
  let mod_cmds = (scope commands | get name | where ($it | str starts-with "mod "))
  let plumbing = ["conn" "cache" "query" "config" "version"]
  for cmd in $mod_cmds {
    # leaf = the segment right after "mod "
    let leaf = ($cmd | str replace "mod " "" | split row " " | first)
    assert ($leaf not-in $plumbing) $"plumbing leaked via: ($cmd)"
  }
}
