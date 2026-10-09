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
  export def query [...terms: string, --last(-L): duration, --start(-a): datetime, --end(-b): datetime, --connection(-c): string] { }
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

# ---- flag / range-flags: the parser-first read ----------------------------------

@test
def "flag reads a duration literal whole on a real signature" [] {
  # the flattened token stream splits `1hr` into `1` + `hr`; the Named read keeps it
  assert equal (complete flag "fakedb query up --last 1hr" [--last -L]) "1hr"
  assert equal (complete flag "fakedb query up -L 15min" [--last -L]) "15min"
  assert equal (complete flag "fakedb query up --last=1hr" [--last -L]) "1hr"
  assert equal (complete flag "fakedb query up --last 1hr -L 2hr" [--last -L]) "2hr"   # last occurrence wins
  assert equal (complete flag "fakedb query up -a 2026-01-01T00:00:00Z" [--start -a]) "2026-01-01T00:00:00Z"
  assert equal (complete flag 'fakedb query up -c "vm dev" j' [--connection -c]) "vm dev"
}

@test
def "flag falls back to the token scan for an external head, a bare flag and a foreign flag" [] {
  assert equal (complete flag "x query --last 1hr" [--last -L]) "1hr"                # unknown command: no Named args
  assert equal (complete flag "fakedb query --last -c pg" [--last -L]) null           # bare flag followed by another flag
  assert equal (complete flag "fakedb query --last " [--last -L]) null                # value still under the cursor
  assert equal (complete flag 'fakedb query --from "users u"' [--from -F]) "users u"  # a flag the command does not declare
}

@test
def "range-flags types the window and nulls the rest" [] {
  assert equal (complete range-flags "fakedb query up --last 1hr") {last: 1hr, start: null, end: null}
  assert equal (complete range-flags "fakedb query up -a 2026-01-01T00:00:00Z -b 2026-01-02T00:00:00Z") {last: null, start: 2026-01-01T00:00:00Z, end: 2026-01-02T00:00:00Z}
  assert equal (complete range-flags "fakedb query up") {last: null, start: null, end: null}
  assert equal (complete range-flags "fakedb query up --last nope") {last: null, start: null, end: null}
}
