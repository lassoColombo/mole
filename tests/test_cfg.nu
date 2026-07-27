use std/assert
use std/testing *

use ../cfg.nu

@before-each
def setup [] {
  let temp = mktemp --tmpdir --directory
  let mole_dir = [$temp mole] | path join
  mkdir $mole_dir
  {
    connections: {
      psql: [
        {name: "db1", driver: "postgres", host: "h", password: "s3cr3t"}
        {name: "db2", driver: "postgres", host: "h2"}
      ]
    }
  } | to yaml | save ([$mole_dir connections.yaml] | path join)
  { temp: $temp }
}

@after-each
def cleanup [] {
  let ctx = $in
  rm --recursive $ctx.temp
}

@test
def "file returns connections.yaml path under XDG dir" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp
  let f = cfg file
  assert str contains $f "mole/connections.yaml"
  assert ($f | str starts-with $ctx.temp)
}

@test
def "show name masked drops password column" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp
  let r = cfg show "db1"
  assert equal ($r | describe | str starts-with "record") true
  assert equal ("password" in ($r | columns)) false
  assert equal $r.name "db1"
}

@test
def "show name raw keeps password" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp
  let r = cfg show "db1" --raw
  assert equal ("password" in ($r | columns)) true
  assert equal $r.password "s3cr3t"
}

@test
def "show all masked groups by source without password" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp
  let t = cfg show
  # grouped by source: a record with a `psql` section holding both rows
  assert equal ($t | describe | str starts-with "record") true
  assert equal ($t.psql | length) 2
  let has_password = $t.psql | any {|row| "password" in ($row | columns) }
  assert equal $has_password false
}
