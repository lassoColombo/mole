use std/assert
use std/testing *
use mole-trino
use mole/lib/cache.nu

# A throwaway config (a trino + a psql connection, the latter to be rejected by the
# cross-driver test) and a throwaway cache dir for the seeded schema tests.
def --env fixture [] {
  let d = (mktemp -d)
  mkdir ([$d mole] | path join)
  {connections: {
    trino: [{name: trino-local-dev, host: "127.0.0.1", port: 8080, user: admin, catalog: tpch, schema: tiny}]
    psql:  [{name: postgres-local-dev, host: "127.0.0.1", port: 5432, user: app, password: secret, database: app}]
  }}
  | to yaml
  | save --force ([$d mole connections.yaml] | path join)
  $env.XDG_CONFIG_HOME = $d
  $env.XDG_CACHE_HOME = ([$d cache] | path join)
}

# The schema cache the driver would have built for trino-local-dev/tpch.tiny.
def seed-schema [] {
  {
    meta: {connection: trino-local-dev, catalog: tpch, schema: tiny, driver: trino, refreshed_at: (date now)}
    tables: [
      {schema: tiny, name: customer, type: "BASE TABLE", comment: null, row_estimate: 0}
      {schema: tiny, name: orders,   type: "BASE TABLE", comment: null, row_estimate: 0}
    ]
    columns: [
      {schema: tiny, table: customer, name: custkey, position: 1, data_type: bigint,  udt_name: bigint,  nullable: false, default: null, char_max_length: null, numeric_precision: null, numeric_scale: null, comment: null, display_type: bigint}
      {schema: tiny, table: customer, name: name,    position: 2, data_type: varchar, udt_name: varchar, nullable: false, default: null, char_max_length: null, numeric_precision: null, numeric_scale: null, comment: null, display_type: varchar}
      {schema: tiny, table: orders,   name: custkey, position: 1, data_type: bigint,  udt_name: bigint,  nullable: false, default: null, char_max_length: null, numeric_precision: null, numeric_scale: null, comment: null, display_type: bigint}
    ]
    constraints: []
  } | cache write (cache path "trino" "trino-local-dev__tpch.tiny")
}

@test
def "dry-run select assembly" [] {
  fixture
  assert equal (mole-trino select --from customer -c trino-local-dev --dry-run | get query) "SELECT * FROM customer"
  assert equal (mole-trino select custkey name acctbal --from customer --where-sql "acctbal > 5000" --sort-by acctbal:desc --limit 5 -c trino-local-dev --dry-run | get query) "SELECT custkey, name, acctbal FROM customer WHERE acctbal > 5000 ORDER BY acctbal DESC LIMIT 5"
  assert equal (mole-trino select mktsegment --distinct --from customer -c trino-local-dev --dry-run | get query) "SELECT DISTINCT mktsegment FROM customer"
  # Trino's grammar is `[OFFSET n] [LIMIT n]` — `LIMIT 5 OFFSET 10` is a server-side syntax error
  assert equal (mole-trino select --from customer --sort-by custkey --limit 5 --offset 10 -c trino-local-dev --dry-run | get query) "SELECT * FROM customer ORDER BY custkey OFFSET 10 LIMIT 5"
}

# ---- stats: dry-run SQL assembly ----------------------------------------------

@test
def "dry-run stats count and sum per group ordered top-n" [] {
  fixture
  assert equal (mole-trino stats --from customer --by mktsegment --count --sum acctbal --sort-by sum_acctbal:desc --limit 10 -c trino-local-dev --dry-run | get query) "SELECT mktsegment, count(*) AS count, sum(acctbal) AS sum_acctbal FROM customer GROUP BY mktsegment ORDER BY sum_acctbal DESC LIMIT 10"
  assert equal (mole-trino stats --from customer --by mktsegment --count --sort-by count:desc --limit 2 --offset 1 -c trino-local-dev --dry-run | get query) "SELECT mktsegment, count(*) AS count FROM customer GROUP BY mktsegment ORDER BY count DESC OFFSET 1 LIMIT 2"
}

@test
def "dry-run stats with where and having over result aliases" [] {
  fixture
  assert equal (mole-trino stats --from customer --by mktsegment,nationkey --count --avg acctbal --where acctbal>0 --having count>=10 --sort-by avg_acctbal:desc -c trino-local-dev --dry-run | get query) "SELECT mktsegment, nationkey, count(*) AS count, avg(acctbal) AS avg_acctbal FROM customer WHERE acctbal > 0 GROUP BY mktsegment, nationkey HAVING count(*) >= 10 ORDER BY avg_acctbal DESC"
}

@test
def "dry-run stats grand total distinct count and the trino dialect aggregates" [] {
  fixture
  assert equal (mole-trino stats --from customer --count --sum acctbal -c trino-local-dev --dry-run | get query) "SELECT count(*) AS count, sum(acctbal) AS sum_acctbal FROM customer"
  assert equal (mole-trino stats --from customer --by mktsegment --count-distinct nationkey -c trino-local-dev --dry-run | get query) "SELECT mktsegment, count(distinct nationkey) AS count_distinct_nationkey FROM customer GROUP BY mktsegment"
  assert equal (mole-trino stats --from customer --by mktsegment --approx-distinct nationkey --string-agg name -c trino-local-dev --dry-run | get query) "SELECT mktsegment, approx_distinct(nationkey) AS approx_distinct_nationkey, listagg(name, ',') WITHIN GROUP (ORDER BY name) AS string_agg_name FROM customer GROUP BY mktsegment"
  assert equal (mole-trino stats --from customer --by mktsegment -c trino-local-dev --dry-run | get query) "SELECT mktsegment, count(*) AS count FROM customer GROUP BY mktsegment"
  assert error { mole-trino stats -c trino-local-dev --dry-run }
}

@test
def "dry-run where token-list, raw --where-sql, IN LIKE NULL and the regexp_like operator" [] {
  fixture
  assert equal (mole-trino select custkey name --from customer --where mktsegment=BUILDING,acctbal>=5000 -c trino-local-dev --dry-run | get query) "SELECT custkey, name FROM customer WHERE mktsegment = 'BUILDING' AND acctbal >= 5000"
  assert equal (mole-trino select --from customer --where-sql "acctbal > 0 AND mktsegment <> 'AUTOMOBILE'" -c trino-local-dev --dry-run | get query) "SELECT * FROM customer WHERE acctbal > 0 AND mktsegment <> 'AUTOMOBILE'"
  assert error { mole-trino select --from customer --where "a=1 AND b=2" -c trino-local-dev --dry-run }   # raw SQL in the token slot errors instead of rendering a = '1 AND b=2'
  assert error { mole-trino select --from customer --where "id = 42" -c trino-local-dev --dry-run }
  assert equal (mole-trino select --from customer --where status=active --where-sql "total > 0 OR legacy" -c trino-local-dev --dry-run | get query) "SELECT * FROM customer WHERE (status = 'active') AND (total > 0 OR legacy)"
  assert equal (mole-trino select --from customer --where mktsegment=in:BUILDING,MACHINERY,name~%Corp%,phone=null -c trino-local-dev --dry-run | get query) "SELECT * FROM customer WHERE mktsegment IN ('BUILDING', 'MACHINERY') AND name LIKE '%Corp%' AND phone IS NULL"
  assert equal (mole-trino select --from customer --where "name=~^A" -c trino-local-dev --dry-run | get query) "SELECT * FROM customer WHERE regexp_like(name, '^A')"
}

@test
def "dry-run update and delete assembly" [] {
  fixture
  assert equal (mole-trino update users status=inactive --where-sql "id = 5" -c trino-local-dev --dry-run | get query) "UPDATE users SET status = 'inactive' WHERE id = 5"
  assert equal (mole-trino update t a=1 b=2 --where-sql "id = 5" -c trino-local-dev --dry-run | get query) "UPDATE t SET a = 1, b = 2 WHERE id = 5"
  assert equal (mole-trino update users archived=true --all -c trino-local-dev --dry-run | get query) "UPDATE users SET archived = true"
  assert equal (mole-trino delete sessions --where user_id=7 -c trino-local-dev --dry-run | get query) "DELETE FROM sessions WHERE user_id = 7"
  assert equal (mole-trino delete sessions --where-sql "expires_at < now()" -c trino-local-dev --dry-run | get query) "DELETE FROM sessions WHERE expires_at < now()"
  assert equal (mole-trino delete staging_rows --all -c trino-local-dev --dry-run | get query) "DELETE FROM staging_rows"
}

@test
def "connection is redacted and tagged and other drivers are rejected" [] {
  fixture
  let c = (mole-trino select --from customer --catalog tpch --schema sf1 -c trino-local-dev --dry-run | get connection)
  assert equal ($c | columns | any {|x| $x == "password"}) false
  assert equal $c.driver "trino"
  assert equal $c.schema "sf1"
  assert error { mole-trino set-connection postgres-local-dev }
}

@test
def "guards error" [] {
  fixture
  assert error { mole-trino select -c trino-local-dev --dry-run }
  assert error { mole-trino select --from t --limit -1 -c trino-local-dev --dry-run }           # negative paging is rejected before the round trip
  assert error { mole-trino select --from t --where "a==1" -c trino-local-dev --dry-run }      # typo'd operator is an error, not a literal
  assert error { mole-trino update t x=1 -c trino-local-dev --dry-run }
  assert error { mole-trino update t x=1 --where " " -c trino-local-dev --dry-run }   # a blank --where is no filter
  assert error { mole-trino delete t --where "," -c trino-local-dev --dry-run }            # nor is a bare comma
  assert error { mole-trino delete t --where-sql " " -c trino-local-dev --dry-run }       # nor a blank raw filter
  assert error { mole-trino update t --where-sql "id = 1" -c trino-local-dev --dry-run }
  assert error { mole-trino delete t -c trino-local-dev --dry-run }
  assert error { mole-trino schema --include a --exclude b -c trino-local-dev }
}

@test
def "schema views read the seeded cache" [] {
  fixture
  seed-schema
  assert equal (mole-trino schema -c trino-local-dev | get name) [customer orders]
  assert equal (mole-trino schema --table customer -c trino-local-dev | get columns.name) [custkey name]
  assert equal (mole-trino schema --find cust -c trino-local-dev | where column == custkey | length) 2
  assert equal (mole-trino schema --full --include orders -c trino-local-dev | get tables.name) [orders]
}

# Drive a completer through the real engine (completers are private, `@`-bound; see
# DESIGN.md): complete the END of `line` after a `use mole-trino` prelude in a child `nu`
# that inherits this test's XDG overrides, and return the candidate values.
def ide-complete [line: string]: nothing -> list<string> {
  let f = (mktemp -t mole-ide.XXXXXX)
  let src = $"use mole-trino\n($line)"
  $src | save --force $f
  # A list-valued NU_LIB_DIRS is dropped on spawn (see run-tests.nu): hand the child a colon string.
  let libs = ($env.NU_LIB_DIRS? | default [])
  let libs = (if ($libs | describe) == "string" { $libs } else { $libs | str join (char esep) })
  let out = (with-env {NU_LIB_DIRS: $libs} { ^nu --no-config-file --ide-complete ($src | encode utf8 | bytes length) $f | complete })
  rm $f
  $out.stdout | from json | get completions | sort
}

# ---- insert: dry-run SQL assembly + guards + completion ------------------------

@test
def "dry-run insert renders tokens by shape and pipes rows by type" [] {
  fixture
  assert equal (mole-trino insert users email=ann@x.io status=active age=30 zip="01234" deleted=null -c trino-local-dev --dry-run | get query) "INSERT INTO users (email, status, age, zip, deleted) VALUES ('ann@x.io', 'active', 30, '01234', NULL)"
  assert equal ([{sku: A1, qty: 3} {sku: B2, qty: 0}] | mole-trino insert stock -c trino-local-dev --dry-run | get query) "INSERT INTO stock (sku, qty) VALUES ('A1', 3), ('B2', 0)"
  assert equal ({sku: A1, qty: "3"} | mole-trino insert stock -c trino-local-dev --dry-run | get query) "INSERT INTO stock (sku, qty) VALUES ('A1', '3')"   # a typed string stays a string
  assert equal ([{sku: A1, qty: null}] | mole-trino insert stock src=import --values-sql {at: "now()"} -c trino-local-dev --dry-run | get query) "INSERT INTO stock (sku, qty, src, at) VALUES ('A1', NULL, 'import', now())"
  assert equal (mole-trino insert events kind=login --values-sql {at: "now()"} -c trino-local-dev --dry-run | get query) "INSERT INTO events (kind, at) VALUES ('login', now())"
  let r = (mole-trino insert t a=1 -c trino-local-dev --dry-run)
  assert equal ($r.connection | columns | any {|x| $x == "password"}) false
}

@test
def "insert refuses nothing ragged rows clashes and non-tokens" [] {
  fixture
  assert error { mole-trino insert users -c trino-local-dev --dry-run }                                           # nothing to insert
  assert error { [{a: 1} {b: 2}] | mole-trino insert t -c trino-local-dev --dry-run }                             # ragged rows
  assert error { [{a: 1}] | mole-trino insert t a=2 -c trino-local-dev --dry-run }                                 # piped + token clash
  assert error { mole-trino insert t a=1 --values-sql {a: "2"} -c trino-local-dev --dry-run }                      # token + expression clash
  assert error { mole-trino insert t "a = 1" -c trino-local-dev --dry-run }                                       # raw SQL is not a token
  assert error { mole-trino insert t "a>=1" -c trino-local-dev --dry-run }                                        # a comparison is not one
  assert error { mole-trino insert t a==1 -c trino-local-dev --dry-run }                                          # operator-looking value
  assert error { mole-trino insert t a=1 a=2 -c trino-local-dev --dry-run }                                       # duplicate column
}

@test
def "insert completes the unassigned columns of the target table" [] {
  fixture
  seed-schema
  assert equal (ide-complete "mole-trino insert -c trino-local-dev ") ["tiny.customer" "tiny.orders"]
  assert equal (ide-complete "mole-trino insert tiny.customer -c trino-local-dev ") ["custkey=" "name="]
  assert equal (ide-complete "mole-trino insert tiny.customer custkey=x -c trino-local-dev ") ["name="]
  assert equal (ide-complete "mole-trino insert tiny.customer custkey=x -c trino-local-dev na") ["name="]
  assert equal (ide-complete "mole-trino insert tiny.customer -c trino-local-dev custkey=") []   # a value probe against an unreachable DB yields nothing, never an error
}

# ---- update: the insert assignment grammar -----------------------------------

@test
def "dry-run update renders assignment tokens and values-sql" [] {
  fixture
  assert equal (mole-trino update users status=active age=30 zip="01234" note=null --all -c trino-local-dev --dry-run | get query) "UPDATE users SET status = 'active', age = 30, zip = '01234', note = NULL"
  assert equal (mole-trino update users status=active --values-sql {seen_at: "now()"} --where id=1 -c trino-local-dev --dry-run | get query) "UPDATE users SET status = 'active', seen_at = now() WHERE id = 1"
  assert error { mole-trino update t "x = 1" --all -c trino-local-dev --dry-run }                    # raw SQL is not an assignment token
  assert error { mole-trino update t x=1 --values-sql {x: "2"} --all -c trino-local-dev --dry-run }   # one column, two values
  assert error { mole-trino update t x=1 x=2 --all -c trino-local-dev --dry-run }                    # assigned twice
  assert error { mole-trino update t --all -c trino-local-dev --dry-run }                            # nothing to set
}

@test
def "update completes assignment tokens like insert" [] {
  fixture
  seed-schema
  assert equal (ide-complete "mole-trino update tiny.customer -c trino-local-dev ") ["custkey=" "name="]
  assert equal (ide-complete "mole-trino update tiny.customer custkey=x -c trino-local-dev ") ["name="]
  assert equal (ide-complete "mole-trino update \"tiny.customer u\" -c trino-local-dev ") ["custkey=" "name="]   # an alias is looked up by its base table
}
