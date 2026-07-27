use std/assert
use std/testing *
use ../lib/conn.nu

@before-each
def setup [] {
  let temp = mktemp --tmpdir --directory
  mkdir ([$temp mole] | path join)
  {
    connections: {
      psql: [{name: "db1", host: "h", password: "p"}]
      vlogs: [{name: "log1"}]
    }
  } | to yaml | save ([$temp mole connections.yaml] | path join)
  { temp: $temp }
}

@after-each
def cleanup [] {
  rm --recursive $in.temp
}

def registry []: nothing -> record {
  { psql: { driver: "psql" }, vlogs: { driver: "victorialogs" } }
}

@test
def "list tags drivers from section keys" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp

  let out = conn list
  assert equal ($out | where name == "db1" | first | get driver) "psql"
  assert equal ($out | where name == "log1" | first | get driver) "vlogs"
}

@test
def "names returns only a given drivers own connection names" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp

  assert equal (conn names "psql") ["db1"]
  assert equal (conn names "vlogs") ["log1"]
  assert equal (conn names "nope") []
}

@test
def "read errors on the old flat connections list" [] {
  let ctx = $in
  { connections: [{name: "x"}] } | to yaml
    | save -f ([$ctx.temp mole connections.yaml] | path join)
  $env.XDG_CONFIG_HOME = $ctx.temp
  assert error { conn list }
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
def "resolve by driver uses current connection" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp
  $env.MOLE_REGISTRY = (registry)
  $env.MOLE_CURRENT = { psql: "db1" }

  let c = conn resolve --driver psql
  assert equal $c.name "db1"
}

@test
def "resolve errors on unknown name and driver mismatch" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp
  $env.MOLE_REGISTRY = (registry)

  assert error { conn resolve "nope" }
  assert error { conn resolve "log1" --driver psql }
}

@test
def "override applies non-null and ignores null" [] {
  let out = {a: 1, b: 2} | conn override {b: 99, c: null}
  assert equal $out.b 99
  assert equal $out.a 1
  assert equal ("c" in ($out | columns)) false
}

@test
def "redact drops secret-looking fields, keeps the rest" [] {
  let out = {name: "c", host: "h", password: "p", token: "t", secret_key: "s"} | conn redact
  assert equal ($out | columns) ["name" "host"]
  assert equal ({} | conn redact) {}
}
