use std/assert
use std/testing *
use mole-duckdb
use mole/lib/cache.nu

# A throwaway config (a duckdb + a psql connection, the latter to be rejected by the
# cross-driver test) and a throwaway cache dir for the seeded schema tests.
def --env fixture [] {
  let d = (mktemp -d)
  mkdir ([$d mole] | path join)
  {connections: {
    duckdb: [{name: duckdb-local-dev, path: "/tmp/app.duckdb"}]
    psql:   [{name: postgres-local-dev, host: "127.0.0.1", port: 5432, user: app, password: secret, database: app}]
  }}
  | to yaml
  | save --force ([$d mole connections.yaml] | path join)
  $env.XDG_CONFIG_HOME = $d
  $env.XDG_CACHE_HOME = ([$d cache] | path join)
}

# The schema cache the driver would have built for duckdb-local-dev/app.duckdb.
def seed-schema [] {
  {
    meta: {connection: duckdb-local-dev, database: "/tmp/app.duckdb", driver: duckdb, refreshed_at: (date now)}
    tables: [
      {schema: main, name: users,  type: "BASE TABLE", comment: null, row_estimate: 5}
      {schema: main, name: orders, type: "BASE TABLE", comment: null, row_estimate: 9}
    ]
    columns: [
      {schema: main, table: users,  name: id,      position: 1, data_type: INTEGER, udt_name: INTEGER, nullable: false, default: null, char_max_length: null, numeric_precision: 32, numeric_scale: 0, comment: null, display_type: INTEGER}
      {schema: main, table: users,  name: email,   position: 2, data_type: VARCHAR, udt_name: VARCHAR, nullable: false, default: null, char_max_length: null, numeric_precision: null, numeric_scale: null, comment: null, display_type: VARCHAR}
      {schema: main, table: orders, name: user_id, position: 1, data_type: INTEGER, udt_name: INTEGER, nullable: false, default: null, char_max_length: null, numeric_precision: 32, numeric_scale: 0, comment: null, display_type: INTEGER}
    ]
    constraints: [
      {schema: main, table: orders, name: orders_fk, type: "FOREIGN KEY", columns: [user_id], ref_schema: main, ref_table: users, ref_columns: [id]}
    ]
  } | cache write (cache path "duckdb" "duckdb-local-dev__app.duckdb")
}

@test
def "dry-run select assembly" [] {
  fixture
  assert equal (mole-duckdb select --from users -c duckdb-local-dev --dry-run | get query) "SELECT * FROM users"
  assert equal (mole-duckdb select id email --from users --where "age > 30" --sort-by age:desc --limit 5 -c duckdb-local-dev --dry-run | get query) "SELECT id, email FROM users WHERE age > 30 ORDER BY age DESC LIMIT 5"
  assert equal (mole-duckdb select status --distinct --from orders -c duckdb-local-dev --dry-run | get query) "SELECT DISTINCT status FROM orders"
  assert equal (mole-duckdb select user_id status --distinct-on user_id --from orders --sort-by user_id,id:desc -c duckdb-local-dev --dry-run | get query) "SELECT DISTINCT ON (user_id) user_id, status FROM orders ORDER BY user_id, id DESC"
  assert equal (mole-duckdb select --from users --sort-by id --limit 2 --offset 2 -c duckdb-local-dev --dry-run | get query) "SELECT * FROM users ORDER BY id LIMIT 2 OFFSET 2"
}

@test
def "dry-run where token-list raw fallback IN LIKE NULL and the regexp_matches operator" [] {
  fixture
  assert equal (mole-duckdb select id email --from users --where status=active,age>=30 -c duckdb-local-dev --dry-run | get query) "SELECT id, email FROM users WHERE status = 'active' AND age >= 30"
  assert equal (mole-duckdb select --from orders --where "total > 0 AND status <> 'void'" -c duckdb-local-dev --dry-run | get query) "SELECT * FROM orders WHERE total > 0 AND status <> 'void'"
  assert equal (mole-duckdb select --from users --where role=in:admin,ops,name~%acme%,deleted=null -c duckdb-local-dev --dry-run | get query) "SELECT * FROM users WHERE role IN ('admin', 'ops') AND name LIKE '%acme%' AND deleted IS NULL"
  assert equal (mole-duckdb select --from users --where "name=~^A" -c duckdb-local-dev --dry-run | get query) "SELECT * FROM users WHERE regexp_matches(name, '^A')"
}

@test
def "dry-run update and delete assembly" [] {
  fixture
  assert equal (mole-duckdb update users "status = 'inactive'" --where "id = 5" -c duckdb-local-dev --dry-run | get query) "UPDATE users SET status = 'inactive' WHERE id = 5"
  assert equal (mole-duckdb update users "login_count = login_count + 1" --where "id = 42" --returning id,login_count -c duckdb-local-dev --dry-run | get query) "UPDATE users SET login_count = login_count + 1 WHERE id = 42 RETURNING id, login_count"
  assert equal (mole-duckdb update users "archived = true" --all -c duckdb-local-dev --dry-run | get query) "UPDATE users SET archived = true"
  assert equal (mole-duckdb delete sessions --where user_id=7 -c duckdb-local-dev --dry-run | get query) "DELETE FROM sessions WHERE user_id = 7"
  assert equal (mole-duckdb delete sessions --where "expires_at < now()" -c duckdb-local-dev --dry-run | get query) "DELETE FROM sessions WHERE expires_at < now()"
  assert equal (mole-duckdb delete sessions --where "user_id = 7" --returning "*" -c duckdb-local-dev --dry-run | get query) "DELETE FROM sessions WHERE user_id = 7 RETURNING *"
  assert equal (mole-duckdb delete staging_rows --all -c duckdb-local-dev --dry-run | get query) "DELETE FROM staging_rows"
}

@test
def "connection is tagged path overrides apply and other drivers are rejected" [] {
  fixture
  let c = (mole-duckdb select --from users --path ":memory:" -c duckdb-local-dev --dry-run | get connection)
  assert equal $c.driver "duckdb"
  assert equal $c.path ":memory:"
  assert error { mole-duckdb set-connection postgres-local-dev }
}

@test
def "guards error" [] {
  fixture
  assert error { mole-duckdb select -c duckdb-local-dev --dry-run }
  assert error { mole-duckdb select --from users --distinct --distinct-on id -c duckdb-local-dev --dry-run }
  assert error { mole-duckdb update t "x = 1" -c duckdb-local-dev --dry-run }
  assert error { mole-duckdb update t --where "id = 1" -c duckdb-local-dev --dry-run }
  assert error { mole-duckdb delete t -c duckdb-local-dev --dry-run }
  assert error { mole-duckdb schema --include a --exclude b -c duckdb-local-dev }
}

@test
def "schema views read the seeded cache and prune dangling fks" [] {
  fixture
  seed-schema
  assert equal (mole-duckdb schema -c duckdb-local-dev | get name) [users orders]
  assert equal (mole-duckdb schema --table users -c duckdb-local-dev | get columns.name) [id email]
  assert equal (mole-duckdb schema --find mail -c duckdb-local-dev | get column) [email]
  assert equal (mole-duckdb schema --full --include orders -c duckdb-local-dev | get constraints | length) 0
}

# ---- stats: dry-run SQL assembly ----------------------------------------------

@test
def "dry-run stats count and sum per group ordered top-n" [] {
  fixture
  assert equal (mole-duckdb stats --from orders --by user_id --count --sum amount --sort-by sum_amount:desc --limit 10 -c duckdb-local-dev --dry-run | get query) "SELECT user_id, count(*) AS count, sum(amount) AS sum_amount FROM orders GROUP BY user_id ORDER BY sum_amount DESC LIMIT 10"
  assert equal (mole-duckdb stats --from orders --by user_id --count --sort-by count:desc --limit 2 --offset 1 -c duckdb-local-dev --dry-run | get query) "SELECT user_id, count(*) AS count FROM orders GROUP BY user_id ORDER BY count DESC LIMIT 2 OFFSET 1"
}

@test
def "dry-run stats with where and having over result aliases" [] {
  fixture
  assert equal (mole-duckdb stats --from orders --by user_id,status --count --avg amount --where status=paid --having count>=10 --sort-by avg_amount:desc -c duckdb-local-dev --dry-run | get query) "SELECT user_id, status, count(*) AS count, avg(amount) AS avg_amount FROM orders WHERE status = 'paid' GROUP BY user_id, status HAVING count(*) >= 10 ORDER BY avg_amount DESC"
}

@test
def "dry-run stats grand total distinct count and the duckdb dialect aggregates" [] {
  fixture
  assert equal (mole-duckdb stats --from orders --count --sum amount -c duckdb-local-dev --dry-run | get query) "SELECT count(*) AS count, sum(amount) AS sum_amount FROM orders"
  assert equal (mole-duckdb stats --from orders --by status --count-distinct user_id -c duckdb-local-dev --dry-run | get query) "SELECT status, count(distinct user_id) AS count_distinct_user_id FROM orders GROUP BY status"
  assert equal (mole-duckdb stats --from orders --by user_id --median amount --string-agg status -c duckdb-local-dev --dry-run | get query) "SELECT user_id, string_agg(status, ',') AS string_agg_status, median(amount) AS median_amount FROM orders GROUP BY user_id"
  assert equal (mole-duckdb stats --from orders --by user_id -c duckdb-local-dev --dry-run | get query) "SELECT user_id, count(*) AS count FROM orders GROUP BY user_id"
  assert error { mole-duckdb stats -c duckdb-local-dev --dry-run }
}
