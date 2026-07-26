use std/assert
use std/testing *
use ../lib/conn.nu

@before-each
def setup [] {
  let temp = mktemp --tmpdir --directory
  mkdir ([$temp mole] | path join)
  {
    connections: [
      {name: "db1", driver: "postgres", host: "h", password: "p"},
      {name: "log1", driver: "victorialogs"},
    ]
  } | to yaml | save ([$temp mole connections.yaml] | path join)
  { temp: $temp }
}

@after-each
def cleanup [] {
  rm --recursive $in.temp
}

def registry []: nothing -> record {
  { psql: { drivers: ["postgres"] }, vlogs: { drivers: ["victorialogs"] } }
}

@test
def "list tags sources from registry" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp
  $env.MOLE_REGISTRY = (registry)

  let out = conn list
  assert equal ($out | where name == "db1" | first | get source) "psql"
  assert equal ($out | where name == "log1" | first | get source) "vlogs"
}

@test
def "resolve by name returns record with secrets" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp
  $env.MOLE_REGISTRY = (registry)

  let c = conn resolve "db1"
  assert equal $c.name "db1"
  assert equal $c.password "p"
}

@test
def "resolve by source uses current connection" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp
  $env.MOLE_REGISTRY = (registry)
  $env.MOLE_CURRENT = { psql: "db1" }

  let c = conn resolve --source psql
  assert equal $c.name "db1"
}

@test
def "resolve errors on unknown name and source mismatch" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp
  $env.MOLE_REGISTRY = (registry)

  assert error { conn resolve "nope" }
  assert error { conn resolve "log1" --source psql }
}

@test
def "override applies non-null and ignores null" [] {
  let out = {a: 1, b: 2} | conn override {b: 99, c: null}
  assert equal $out.b 99
  assert equal $out.a 1
  assert equal ("c" in ($out | columns)) false
}
