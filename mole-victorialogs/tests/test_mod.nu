use std/assert
use std/testing *
use mole-victorialogs

# Point mole at a throwaway config holding a victorialogs + a psql connection (the
# latter so the cross-driver isolation test has something to reject) and a throwaway
# cache dir. --env so the XDG overrides land in the calling test's environment. Every
# assertion below is `--dry-run`: no server is contacted.
def --env fixture [] {
  let d = (mktemp -d)
  mkdir ([$d mole] | path join)
  {connections: {
    victorialogs: [{name: vl-local, url: "http://127.0.0.1:9428", token: secret}]
    psql:         [{name: postgres-local-dev, host: "127.0.0.1", port: 5432, user: app, password: secret, database: app}]
  }}
  | to yaml
  | save --force ([$d mole connections.yaml] | path join)
  $env.XDG_CONFIG_HOME = $d
  $env.XDG_CACHE_HOME = ([$d cache] | path join)
}

# ---- select -------------------------------------------------------------------

@test
def "dry-run select composes filter, projection, sort and paging in order" [] {
  fixture
  assert equal (mole-victorialogs select level:error status:>=500 --select _time,host,_msg --sort-by _time --desc --limit 100 -c vl-local --dry-run | get query) "level:error status:>=500 | fields _time, host, _msg | sort by (_time) desc | limit 100"
  assert equal (mole-victorialogs select --limit 10 -c vl-local --dry-run | get query) "* | limit 10"
  # paging rides the pipeline (`| offset` before `| limit`), never the HTTP offset
  assert equal (mole-victorialogs select level:error --sort-by _time --desc --offset 10 --limit 10 -c vl-local --dry-run | get query) "level:error | sort by (_time) desc | offset 10 | limit 10"
  assert equal (mole-victorialogs select 'db timeout' --after 2 --drop _stream_id -c vl-local --dry-run | get query) "db timeout | stream_context after 2 | delete _stream_id"
}

@test
def "select rejects tokens that would silently match nothing" [] {
  fixture
  assert error { mole-victorialogs select "status>=500" -c vl-local --dry-run }            # bare range → word filter
  assert error { mole-victorialogs select -- "-status>=500" -c vl-local --dry-run }        # negated bare range
  assert error { mole-victorialogs select "level:error | stats count()" -c vl-local --dry-run }   # a smuggled pipe
  assert error { mole-victorialogs select --limit -1 -c vl-local --dry-run }
  # a whitespace-only token is dropped, not sent as an empty phrase
  assert equal (mole-victorialogs select "   " -c vl-local --dry-run | get query) "*"
}

@test
def "dry-run redacts the token and tags the victorialogs driver" [] {
  fixture
  let r = (mole-victorialogs select -c vl-local --dry-run)
  assert equal $r.connection.driver "victorialogs"
  assert equal $r.connection.url "http://127.0.0.1:9428"
  assert equal ("token" in ($r.connection | columns)) false
}

# ---- hits / stats -------------------------------------------------------------

@test
def "dry-run hits and the enumeration verbs expose the composed filter" [] {
  fixture
  assert equal (mole-victorialogs hits level:error -c vl-local --dry-run | get query) "level:error"
  assert equal (mole-victorialogs hits -c vl-local --dry-run | get query) "*"
  assert equal (mole-victorialogs fields level:error -c vl-local --dry-run | get query) "level:error"
  assert equal (mole-victorialogs field-values host level:error -c vl-local --dry-run | get query) "level:error"
  assert equal (mole-victorialogs streams level:error --limit 5 -c vl-local --dry-run | get query) "level:error"
  assert equal (mole-victorialogs facets -c vl-local --dry-run | get query) "*"
}

@test
def "dry-run stats composes by-clause, aggregations and top-n" [] {
  fixture
  assert equal (mole-victorialogs stats --by level -c vl-local --dry-run | get query) "* | stats by (level) count() as count"
  assert equal (mole-victorialogs stats level:error --by host --sort-by count --desc --limit 10 -c vl-local --dry-run | get query) "level:error | stats by (host) count() as count | sort by (count) desc | limit 10"
  assert equal (mole-victorialogs stats --by app --avg latency_ms --p95 latency_ms -c vl-local --dry-run | get query) "* | stats by (app) avg(latency_ms) as avg_latency_ms, quantile(0.95, latency_ms) as p95_latency_ms"
}

@test
def "stats refuses duplicate or clashing result columns" [] {
  fixture
  assert error { mole-victorialogs stats --sum bytes,bytes -c vl-local --dry-run }
  assert error { mole-victorialogs stats --by count --count -c vl-local --dry-run }
}

# ---- connections --------------------------------------------------------------

@test
def "set-connection rejects a non-victorialogs connection" [] {
  fixture
  assert error { mole-victorialogs set-connection postgres-local-dev }
  assert error { mole-victorialogs select -c postgres-local-dev --dry-run }
}
