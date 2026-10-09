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
  assert equal (mole-trino select custkey name acctbal --from customer --where "acctbal > 5000" --sort-by acctbal:desc --limit 5 -c trino-local-dev --dry-run | get query) "SELECT custkey, name, acctbal FROM customer WHERE acctbal > 5000 ORDER BY acctbal DESC LIMIT 5"
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
def "dry-run where token-list raw fallback IN LIKE NULL and the regexp_like operator" [] {
  fixture
  assert equal (mole-trino select custkey name --from customer --where mktsegment=BUILDING,acctbal>=5000 -c trino-local-dev --dry-run | get query) "SELECT custkey, name FROM customer WHERE mktsegment = 'BUILDING' AND acctbal >= 5000"
  assert equal (mole-trino select --from customer --where "acctbal > 0 AND mktsegment <> 'AUTOMOBILE'" -c trino-local-dev --dry-run | get query) "SELECT * FROM customer WHERE acctbal > 0 AND mktsegment <> 'AUTOMOBILE'"
  assert equal (mole-trino select --from customer --where mktsegment=in:BUILDING,MACHINERY,name~%Corp%,phone=null -c trino-local-dev --dry-run | get query) "SELECT * FROM customer WHERE mktsegment IN ('BUILDING', 'MACHINERY') AND name LIKE '%Corp%' AND phone IS NULL"
  assert equal (mole-trino select --from customer --where "name=~^A" -c trino-local-dev --dry-run | get query) "SELECT * FROM customer WHERE regexp_like(name, '^A')"
}

@test
def "dry-run update and delete assembly" [] {
  fixture
  assert equal (mole-trino update users "status = 'inactive'" --where "id = 5" -c trino-local-dev --dry-run | get query) "UPDATE users SET status = 'inactive' WHERE id = 5"
  assert equal (mole-trino update t "a = 1" "b = 2" --where "id = 5" -c trino-local-dev --dry-run | get query) "UPDATE t SET a = 1, b = 2 WHERE id = 5"
  assert equal (mole-trino update users "archived = true" --all -c trino-local-dev --dry-run | get query) "UPDATE users SET archived = true"
  assert equal (mole-trino delete sessions --where user_id=7 -c trino-local-dev --dry-run | get query) "DELETE FROM sessions WHERE user_id = 7"
  assert equal (mole-trino delete sessions --where "expires_at < now()" -c trino-local-dev --dry-run | get query) "DELETE FROM sessions WHERE expires_at < now()"
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
  assert error { mole-trino update t "x = 1" -c trino-local-dev --dry-run }
  assert error { mole-trino update t --where "id = 1" -c trino-local-dev --dry-run }
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
