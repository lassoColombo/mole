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

@test
def "csv-extend re-prepends the typed comma prefix" [] {
  assert equal (complete csv-extend "stats --by job," [method host]) ["job,method" "job,host"]
  assert equal (complete csv-extend "stats --by job,me" [method]) ["job,method"]
  assert equal (complete csv-extend "stats --by " [job host]) [job host]
}

# A stand-in driver so `ast` can parse write-verb lines with real signatures.
module fakedb {
  export def update [table: string, ...assignments: string, --where: string] { }
  export def delete [table: string, --where: string] { }
  export def show [...columns: string, --from: string, --where: string] { }
}
use fakedb

@test
def "lead-arg returns the write verbs leading table, unquoted" [] {
  assert equal (complete lead-arg 'fakedb update users "a = 1" --where ' [update delete]) "users"
  assert equal (complete lead-arg 'fakedb update "users u" "a = 1" --where ' [update delete]) "users u"
  assert equal (complete lead-arg "fakedb delete sessions --where " [update delete]) "sessions"
}

@test
def "lead-arg is null on other verbs or an empty slot" [] {
  assert equal (complete lead-arg "fakedb show id --from users --where " [update delete]) null
  assert equal (complete lead-arg "fakedb update " [update delete]) null
}
