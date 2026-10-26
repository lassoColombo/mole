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
  assert equal (mole-duckdb select id email --from users --where-sql "age > 30" --sort-by age:desc --limit 5 -c duckdb-local-dev --dry-run | get query) "SELECT id, email FROM users WHERE age > 30 ORDER BY age DESC LIMIT 5"
  assert equal (mole-duckdb select status --distinct --from orders -c duckdb-local-dev --dry-run | get query) "SELECT DISTINCT status FROM orders"
  assert equal (mole-duckdb select user_id status --distinct-on user_id --from orders --sort-by user_id,id:desc -c duckdb-local-dev --dry-run | get query) "SELECT DISTINCT ON (user_id) user_id, status FROM orders ORDER BY user_id, id DESC"
  assert equal (mole-duckdb select --from users --sort-by id --limit 2 --offset 2 -c duckdb-local-dev --dry-run | get query) "SELECT * FROM users ORDER BY id LIMIT 2 OFFSET 2"
}

@test
def "dry-run where token-list, raw --where-sql, IN LIKE NULL and the regexp_matches operator" [] {
  fixture
  assert equal (mole-duckdb select id email --from users --where status=active,age>=30 -c duckdb-local-dev --dry-run | get query) "SELECT id, email FROM users WHERE status = 'active' AND age >= 30"
  assert equal (mole-duckdb select --from orders --where-sql "total > 0 AND status <> 'void'" -c duckdb-local-dev --dry-run | get query) "SELECT * FROM orders WHERE total > 0 AND status <> 'void'"
  assert error { mole-duckdb select --from orders --where "a=1 AND b=2" -c duckdb-local-dev --dry-run }   # raw SQL in the token slot errors instead of rendering a = '1 AND b=2'
  assert error { mole-duckdb select --from orders --where "id = 42" -c duckdb-local-dev --dry-run }
  assert equal (mole-duckdb select --from orders --where status=active --where-sql "total > 0 OR legacy" -c duckdb-local-dev --dry-run | get query) "SELECT * FROM orders WHERE (status = 'active') AND (total > 0 OR legacy)"
  assert equal (mole-duckdb select --from users --where role=in:admin,ops,name~%acme%,deleted=null -c duckdb-local-dev --dry-run | get query) "SELECT * FROM users WHERE role IN ('admin', 'ops') AND name LIKE '%acme%' AND deleted IS NULL"
  assert equal (mole-duckdb select --from users --where "name=~^A" -c duckdb-local-dev --dry-run | get query) "SELECT * FROM users WHERE regexp_matches(name, '^A')"
}

@test
def "dry-run update and delete assembly" [] {
  fixture
  assert equal (mole-duckdb update users status=inactive --where-sql "id = 5" -c duckdb-local-dev --dry-run | get query) "UPDATE users SET status = 'inactive' WHERE id = 5"
  assert equal (mole-duckdb update users --values-sql {login_count: "login_count + 1"} --where-sql "id = 42" --returning id,login_count -c duckdb-local-dev --dry-run | get query) "UPDATE users SET login_count = login_count + 1 WHERE id = 42 RETURNING id, login_count"
  assert equal (mole-duckdb update users archived=true --all -c duckdb-local-dev --dry-run | get query) "UPDATE users SET archived = true"
  assert equal (mole-duckdb delete sessions --where user_id=7 -c duckdb-local-dev --dry-run | get query) "DELETE FROM sessions WHERE user_id = 7"
  assert equal (mole-duckdb delete sessions --where-sql "expires_at < now()" -c duckdb-local-dev --dry-run | get query) "DELETE FROM sessions WHERE expires_at < now()"
  assert equal (mole-duckdb delete sessions --where-sql "user_id = 7" --returning "*" -c duckdb-local-dev --dry-run | get query) "DELETE FROM sessions WHERE user_id = 7 RETURNING *"
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
  assert error { mole-duckdb select --from t --limit -1 -c duckdb-local-dev --dry-run }           # negative paging is rejected before the round trip
  assert error { mole-duckdb select --from t --where "a==1" -c duckdb-local-dev --dry-run }      # typo'd operator is an error, not a literal
  assert error { mole-duckdb select --from users --distinct --distinct-on id -c duckdb-local-dev --dry-run }
  assert error { mole-duckdb update t x=1 -c duckdb-local-dev --dry-run }
  assert error { mole-duckdb update t x=1 --where " " -c duckdb-local-dev --dry-run }   # a blank --where is no filter
  assert error { mole-duckdb delete t --where "," -c duckdb-local-dev --dry-run }            # nor is a bare comma
  assert error { mole-duckdb delete t --where-sql " " -c duckdb-local-dev --dry-run }       # nor a blank raw filter
  assert error { mole-duckdb update t --where-sql "id = 1" -c duckdb-local-dev --dry-run }
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

# Drive a completer through the real engine (completers are private, `@`-bound; see
# DESIGN.md): complete the END of `line` after a `use mole-duckdb` prelude in a child `nu`
# that inherits this test's XDG overrides, and return the candidate values.
def ide-complete [line: string]: nothing -> list<string> {
  let f = (mktemp -t mole-ide.XXXXXX)
  let src = $"use mole-duckdb\n($line)"
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
  assert equal (mole-duckdb insert users email=ann@x.io status=active age=30 zip="01234" deleted=null -c duckdb-local-dev --dry-run | get query) "INSERT INTO users (email, status, age, zip, deleted) VALUES ('ann@x.io', 'active', 30, '01234', NULL)"
  assert equal ([{sku: A1, qty: 3} {sku: B2, qty: 0}] | mole-duckdb insert stock -c duckdb-local-dev --dry-run | get query) "INSERT INTO stock (sku, qty) VALUES ('A1', 3), ('B2', 0)"
  assert equal ({sku: A1, qty: "3"} | mole-duckdb insert stock -c duckdb-local-dev --dry-run | get query) "INSERT INTO stock (sku, qty) VALUES ('A1', '3')"   # a typed string stays a string
  assert equal ([{sku: A1, qty: null}] | mole-duckdb insert stock src=import --values-sql {at: "now()"} -c duckdb-local-dev --dry-run | get query) "INSERT INTO stock (sku, qty, src, at) VALUES ('A1', NULL, 'import', now())"
  assert equal (mole-duckdb insert events kind=login --values-sql {at: "now()"} -c duckdb-local-dev --dry-run | get query) "INSERT INTO events (kind, at) VALUES ('login', now())"
  let r = (mole-duckdb insert t a=1 -c duckdb-local-dev --dry-run)
  assert equal ($r.connection | columns | any {|x| $x == "password"}) false
}

@test
def "insert refuses nothing ragged rows clashes and non-tokens" [] {
  fixture
  assert error { mole-duckdb insert users -c duckdb-local-dev --dry-run }                                           # nothing to insert
  assert error { [{a: 1} {b: 2}] | mole-duckdb insert t -c duckdb-local-dev --dry-run }                             # ragged rows
  assert error { [{a: 1}] | mole-duckdb insert t a=2 -c duckdb-local-dev --dry-run }                                 # piped + token clash
  assert error { mole-duckdb insert t a=1 --values-sql {a: "2"} -c duckdb-local-dev --dry-run }                      # token + expression clash
  assert error { mole-duckdb insert t "a = 1" -c duckdb-local-dev --dry-run }                                       # raw SQL is not a token
  assert error { mole-duckdb insert t "a>=1" -c duckdb-local-dev --dry-run }                                        # a comparison is not one
  assert error { mole-duckdb insert t a==1 -c duckdb-local-dev --dry-run }                                          # operator-looking value
  assert error { mole-duckdb insert t a=1 a=2 -c duckdb-local-dev --dry-run }                                       # duplicate column
}

@test
def "dry-run insert conflict clauses and returning" [] {
  fixture
  assert equal (mole-duckdb insert users email=a@b.c --ignore -c duckdb-local-dev --dry-run | get query) "INSERT INTO users (email) VALUES ('a@b.c') ON CONFLICT DO NOTHING"
  assert equal (mole-duckdb insert users email=a@b.c status=active --upsert email --returning id -c duckdb-local-dev --dry-run | get query) "INSERT INTO users (email, status) VALUES ('a@b.c', 'active') ON CONFLICT (email) DO UPDATE SET status = EXCLUDED.status RETURNING id"
  assert equal (mole-duckdb insert users email=a@b.c --upsert email -c duckdb-local-dev --dry-run | get query) "INSERT INTO users (email) VALUES ('a@b.c') ON CONFLICT (email) DO NOTHING"   # nothing left to SET
  assert equal (mole-duckdb insert t a=1 b=2 c=3 --upsert a,b -c duckdb-local-dev --dry-run | get query) "INSERT INTO t (a, b, c) VALUES (1, 2, 3) ON CONFLICT (a, b) DO UPDATE SET c = EXCLUDED.c"
  assert equal (mole-duckdb insert users email=a@b.c --returning "*" -c duckdb-local-dev --dry-run | get query) "INSERT INTO users (email) VALUES ('a@b.c') RETURNING *"
  assert error { mole-duckdb insert users email=a --ignore --upsert email -c duckdb-local-dev --dry-run }
}

@test
def "insert completes the unassigned columns of the target table" [] {
  fixture
  seed-schema
  assert equal (ide-complete "mole-duckdb insert -c duckdb-local-dev ") ["main.orders" "main.users"]
  assert equal (ide-complete "mole-duckdb insert main.users -c duckdb-local-dev ") ["email=" "id="]
  assert equal (ide-complete "mole-duckdb insert main.users id=x -c duckdb-local-dev ") ["email="]
  assert equal (ide-complete "mole-duckdb insert main.users id=x -c duckdb-local-dev em") ["email="]
  assert equal (ide-complete "mole-duckdb insert main.users -c duckdb-local-dev --upsert ") ["email" "id"]
  assert equal (ide-complete "mole-duckdb insert main.users -c duckdb-local-dev id=") []   # a value probe against an unreachable DB yields nothing, never an error
}

# ---- update: the insert assignment grammar -----------------------------------

@test
def "dry-run update renders assignment tokens and values-sql" [] {
  fixture
  assert equal (mole-duckdb update users status=active age=30 zip="01234" note=null --all -c duckdb-local-dev --dry-run | get query) "UPDATE users SET status = 'active', age = 30, zip = '01234', note = NULL"
  assert equal (mole-duckdb update users status=active --values-sql {seen_at: "now()"} --where id=1 -c duckdb-local-dev --dry-run | get query) "UPDATE users SET status = 'active', seen_at = now() WHERE id = 1"
  assert error { mole-duckdb update t "x = 1" --all -c duckdb-local-dev --dry-run }                    # raw SQL is not an assignment token
  assert error { mole-duckdb update t x=1 --values-sql {x: "2"} --all -c duckdb-local-dev --dry-run }   # one column, two values
  assert error { mole-duckdb update t x=1 x=2 --all -c duckdb-local-dev --dry-run }                    # assigned twice
  assert error { mole-duckdb update t --all -c duckdb-local-dev --dry-run }                            # nothing to set
}

@test
def "update completes assignment tokens like insert" [] {
  fixture
  seed-schema
  assert equal (ide-complete "mole-duckdb update main.users -c duckdb-local-dev ") ["email=" "id="]
  assert equal (ide-complete "mole-duckdb update main.users id=x -c duckdb-local-dev ") ["email="]
  assert equal (ide-complete "mole-duckdb update \"main.users u\" -c duckdb-local-dev ") ["email=" "id="]   # an alias is looked up by its base table
}
