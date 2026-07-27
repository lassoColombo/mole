use std/assert
use std/testing *

use ../lib/complete.nu

@before-each
def setup [] {
  let temp = mktemp --tmpdir --directory
  mkdir ($temp | path join mole)
  {
    connections: {
      psql: [
        { name: "db1" }
        { name: "db2" }
      ]
    }
  } | to yaml | save ($temp | path join mole connections.yaml)
  mkdir ($temp | path join mole queries sub)
  "x" | save ($temp | path join mole queries a.sql)
  "y" | save ($temp | path join mole queries sub b.sql)
  { temp: $temp }
}

@after-each
def cleanup [] {
  let ctx = $in
  rm --recursive $ctx.temp
}

@test
def "connection returns all connection names" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp
  let result = complete connection
  assert length $result 2
  assert ("db1" in $result)
  assert ("db2" in $result)
}

@test
def "queryfile returns files as relative paths" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp
  let result = complete queryfile
  assert length $result 2
  assert ("a.sql" in $result)
  assert ("sub/b.sql" in $result)
}

@test
def "queryfile returns empty list when query dir missing" [] {
  let ctx = $in
  let empty = mktemp --tmpdir --directory
  $env.XDG_CONFIG_HOME = $empty
  let result = complete queryfile
  rm --recursive $empty
  assert length $result 0
}
