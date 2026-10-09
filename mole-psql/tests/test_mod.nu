use std/assert
use std/testing *
use mole-psql
use mole/lib/cache.nu

# Point mole at a throwaway config holding a psql + a mysql connection (the latter so
# the cross-driver isolation test has something to reject) and at a throwaway cache
# dir, so the schema tests can seed a catalog without a live database. --env so the
# XDG overrides land in the calling test's environment.
def --env fixture [] {
  let d = (mktemp -d)
  mkdir ([$d mole] | path join)
  {connections: {
    psql:  [{name: postgres-local-dev, host: "127.0.0.1", port: 5432, user: app, password: secret, database: app}]
    mysql: [{name: mysql-local-dev, host: "127.0.0.1", port: 3306, user: root, password: secret, database: app}]
  }}
  | to yaml
  | save --force ([$d mole connections.yaml] | path join)
  $env.XDG_CONFIG_HOME = $d
  $env.XDG_CACHE_HOME = ([$d cache] | path join)
}

# Seed the schema cache the driver would have built for postgres-local-dev/app, with a
# real `refreshed_at` so `cache fetch` serves it instead of introspecting.
def seed-schema [] {
  {
    meta: {connection: postgres-local-dev, database: app, driver: psql, refreshed_at: (date now)}
    tables: [
      {schema: public, name: users,  type: "BASE TABLE", comment: "people",  row_estimate: 5}
      {schema: public, name: orders, type: "BASE TABLE", comment: null,      row_estimate: 9}
    ]
    columns: [
      {schema: public, table: users,  name: id,      position: 1, data_type: integer, udt_name: int4, nullable: false, default: null, char_max_length: null, numeric_precision: 32, numeric_scale: 0, comment: "pk", display_type: integer}
      {schema: public, table: users,  name: email,   position: 2, data_type: text,    udt_name: text, nullable: false, default: null, char_max_length: null, numeric_precision: null, numeric_scale: null, comment: null, display_type: text}
      {schema: public, table: orders, name: id,      position: 1, data_type: integer, udt_name: int4, nullable: false, default: null, char_max_length: null, numeric_precision: 32, numeric_scale: 0, comment: null, display_type: integer}
      {schema: public, table: orders, name: user_id, position: 2, data_type: integer, udt_name: int4, nullable: false, default: null, char_max_length: null, numeric_precision: 32, numeric_scale: 0, comment: null, display_type: integer}
    ]
    constraints: [
      {schema: public, table: users,  name: users_pk,  type: "PRIMARY KEY", columns: [id],      ref_schema: null,   ref_table: null,  ref_columns: null}
      {schema: public, table: orders, name: orders_fk, type: "FOREIGN KEY", columns: [user_id], ref_schema: public, ref_table: users, ref_columns: [id]}
    ]
  } | cache write (cache path "psql" "postgres-local-dev__app")
}

# ---- select: dry-run SQL assembly ---------------------------------------------

@test
def "dry-run plain select stars all columns" [] {
  fixture
  assert equal (mole-psql select --from users -c postgres-local-dev --dry-run | get query) "SELECT * FROM users"
}

@test
def "dry-run projects filters orders and limits" [] {
  fixture
  assert equal (mole-psql select id email --from users --where "age > 30" --sort-by age:desc --limit 5 -c postgres-local-dev --dry-run | get query) "SELECT id, email FROM users WHERE age > 30 ORDER BY age DESC LIMIT 5"
}

@test
def "dry-run distinct and distinct on" [] {
  fixture
  assert equal (mole-psql select status --distinct --from orders -c postgres-local-dev --dry-run | get query) "SELECT DISTINCT status FROM orders"
  assert equal (mole-psql select user_id status --distinct-on user_id --from orders --sort-by user_id,id:desc -c postgres-local-dev --dry-run | get query) "SELECT DISTINCT ON (user_id) user_id, status FROM orders ORDER BY user_id, id DESC"
}

@test
def "dry-run pagination and row locks" [] {
  fixture
  assert equal (mole-psql select --from users --sort-by id --limit 2 --offset 2 -c postgres-local-dev --dry-run | get query) "SELECT * FROM users ORDER BY id LIMIT 2 OFFSET 2"
  assert equal (mole-psql select --from orders --where "status = 'pending'" --lock update --skip-locked -c postgres-local-dev --dry-run | get query) "SELECT * FROM orders WHERE status = 'pending' FOR UPDATE SKIP LOCKED"
  assert equal (mole-psql select --from orders --lock share --lock-of orders --nowait -c postgres-local-dev --dry-run | get query) "SELECT * FROM orders FOR SHARE OF orders NOWAIT"
}

@test
def "dry-run where token-list raw fallback and the IN LIKE NULL forms" [] {
  fixture
  assert equal (mole-psql select id email --from users --where status=active,age>=30 -c postgres-local-dev --dry-run | get query) "SELECT id, email FROM users WHERE status = 'active' AND age >= 30"
  assert equal (mole-psql select --from orders --where "total > 0 AND status <> 'void'" -c postgres-local-dev --dry-run | get query) "SELECT * FROM orders WHERE total > 0 AND status <> 'void'"
  assert equal (mole-psql select --from users --where role=in:admin,ops,name~%acme%,deleted=null -c postgres-local-dev --dry-run | get query) "SELECT * FROM users WHERE role IN ('admin', 'ops') AND name LIKE '%acme%' AND deleted IS NULL"
  assert equal (mole-psql select --from users --where "name~*%ACME%" -c postgres-local-dev --dry-run | get query) "SELECT * FROM users WHERE name ILIKE '%ACME%'"
}

@test
def "dry-run passes a window expression through verbatim" [] {
  fixture
  assert equal (mole-psql select email "row_number() over (order by balance desc) AS rk" --from users -c postgres-local-dev --dry-run | get query) "SELECT email, row_number() over (order by balance desc) AS rk FROM users"
}

# ---- connection handling + flag validation ------------------------------------

@test
def "dry-run redacts the password and tags the psql driver" [] {
  fixture
  let c = (mole-psql select --from users -c postgres-local-dev --dry-run | get connection)
  assert equal ($c | columns | any {|x| $x == "password"}) false
  assert equal $c.driver "psql"
}

@test
def "set-connection rejects a non-psql connection" [] {
  fixture
  assert error { mole-psql set-connection mysql-local-dev }
}

@test
def "select flag guards error" [] {
  fixture
  assert error { mole-psql select --from users --distinct --distinct-on id -c postgres-local-dev --dry-run }
  assert error { mole-psql select --from orders --lock update --skip-locked --nowait -c postgres-local-dev --dry-run }
  assert error { mole-psql select --from orders --lock-of t -c postgres-local-dev --dry-run }
  assert error { mole-psql select -c postgres-local-dev --dry-run }
}

# ---- stats: dry-run SQL assembly ----------------------------------------------

@test
def "dry-run stats count and sum per group ordered top-n" [] {
  fixture
  assert equal (mole-psql stats --from orders --by region --count --sum amount --sort-by sum_amount:desc --limit 10 -c postgres-local-dev --dry-run | get query) "SELECT region, count(*) AS count, sum(amount) AS sum_amount FROM orders GROUP BY region ORDER BY sum_amount DESC LIMIT 10"
}

@test
def "dry-run stats with where and having over result aliases" [] {
  fixture
  assert equal (mole-psql stats --from orders --by region,tier --count --avg amount --where status=active --having count>=10 --sort-by avg_amount:desc -c postgres-local-dev --dry-run | get query) "SELECT region, tier, count(*) AS count, avg(amount) AS avg_amount FROM orders WHERE status = 'active' GROUP BY region, tier HAVING count(*) >= 10 ORDER BY avg_amount DESC"
}

@test
def "dry-run stats grand total distinct count and the string-agg dialect aggregate" [] {
  fixture
  assert equal (mole-psql stats --from orders --count --sum amount -c postgres-local-dev --dry-run | get query) "SELECT count(*) AS count, sum(amount) AS sum_amount FROM orders"
  assert equal (mole-psql stats --from orders --by region --count-distinct customer_id -c postgres-local-dev --dry-run | get query) "SELECT region, count(distinct customer_id) AS count_distinct_customer_id FROM orders GROUP BY region"
  assert equal (mole-psql stats --from users --by region --string-agg name -c postgres-local-dev --dry-run | get query) "SELECT region, string_agg(name, ',') AS string_agg_name FROM users GROUP BY region"
  assert equal (mole-psql stats --from orders --by region -c postgres-local-dev --dry-run | get query) "SELECT region, count(*) AS count FROM orders GROUP BY region"
}

# ---- update / delete: dry-run SQL assembly + guards ---------------------------

@test
def "dry-run update sets filters and returns" [] {
  fixture
  assert equal (mole-psql update users "status = 'inactive'" --where "last_login < now() - interval '1 year'" -c postgres-local-dev --dry-run | get query) "UPDATE users SET status = 'inactive' WHERE last_login < now() - interval '1 year'"
  assert equal (mole-psql update users "login_count = login_count + 1" --where id=42 --returning id,login_count -c postgres-local-dev --dry-run | get query) "UPDATE users SET login_count = login_count + 1 WHERE id = 42 RETURNING id, login_count"
  assert equal (mole-psql update users "status = 'active'" "verified = true" --where "email = 'a@b.c'" -c postgres-local-dev --dry-run | get query) "UPDATE users SET status = 'active', verified = true WHERE email = 'a@b.c'"
  assert equal (mole-psql update users "archived = true" --all -c postgres-local-dev --dry-run | get query) "UPDATE users SET archived = true"
}

@test
def "dry-run delete token-list raw and returning" [] {
  fixture
  assert equal (mole-psql delete sessions --where user_id=7 -c postgres-local-dev --dry-run | get query) "DELETE FROM sessions WHERE user_id = 7"
  assert equal (mole-psql delete sessions --where "expires_at < now()" -c postgres-local-dev --dry-run | get query) "DELETE FROM sessions WHERE expires_at < now()"
  assert equal (mole-psql delete sessions --where "user_id = 7" --returning "*" -c postgres-local-dev --dry-run | get query) "DELETE FROM sessions WHERE user_id = 7 RETURNING *"
  assert equal (mole-psql delete staging_rows --all -c postgres-local-dev --dry-run | get query) "DELETE FROM staging_rows"
}

@test
def "write verbs refuse unfiltered writes and empty assignments" [] {
  fixture
  assert error { mole-psql update t "x = 1" -c postgres-local-dev --dry-run }
  assert error { mole-psql update t --where "id = 1" -c postgres-local-dev --dry-run }
  assert error { mole-psql delete t -c postgres-local-dev --dry-run }
  let c = (mole-psql update t "x = 1" --where "id = 1" -c postgres-local-dev --dry-run | get connection)
  assert equal ($c | columns | any {|x| $x == "password"}) false
}

# ---- schema: the views over a seeded cache ------------------------------------

@test
def "schema summary detail find and full read the cache" [] {
  fixture
  seed-schema
  assert equal (mole-psql schema -c postgres-local-dev | get name) [users orders]
  assert equal (mole-psql schema -c postgres-local-dev | where name == users | first | get pk) "id"
  assert equal (mole-psql schema --table users -c postgres-local-dev | get columns.name) [id email]
  assert equal (mole-psql schema --find people -c postgres-local-dev | get kind) ["table-comment"]
  assert equal (mole-psql schema --full -c postgres-local-dev | get meta.driver) "psql"
}

@test
def "schema include and exclude filter every view and prune dangling fks" [] {
  fixture
  seed-schema
  assert equal (mole-psql schema --include users -c postgres-local-dev | get name) [users]
  assert equal (mole-psql schema --exclude "use*" -c postgres-local-dev | get name) [orders]
  assert equal (mole-psql schema --full --include orders -c postgres-local-dev | get constraints | length) 0
  assert error { mole-psql schema --include a --exclude b -c postgres-local-dev }
}
