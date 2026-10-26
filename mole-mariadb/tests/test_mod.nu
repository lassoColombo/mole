use std/assert
use std/testing *
use mole-mariadb
use mole/lib/cache.nu

# Point mole at a throwaway config holding a mariadb + a mysql connection, so
# `select` can resolve one and render dry-run SQL without a live database (and so
# the cross-driver isolation test has a mysql connection to be rejected). --env
# so the XDG override lands in the calling test's environment.
def --env fixture [] {
  let d = (mktemp -d)
  mkdir ([$d mole] | path join)
  {connections: {
    mariadb: [{name: mariadb-local-dev, host: "127.0.0.1", port: 3306, user: root, password: secret, database: app}]
    mysql:   [{name: mysql-local-dev,   host: "127.0.0.1", port: 3306, user: root, password: secret, database: app}]
  }}
  | to yaml
  | save --force ([$d mole connections.yaml] | path join)
  $env.XDG_CONFIG_HOME = $d
}

# Seed the schema cache the driver would have built for mariadb-local-dev/app, with a real
# `refreshed_at` so `cache fetch` serves it instead of introspecting.
def seed-schema [] {
  {
    meta: {connection: mariadb-local-dev, database: app, driver: mariadb, refreshed_at: (date now)}
    tables: [{schema: app, name: users, type: "BASE TABLE", comment: null, row_estimate: 5}]
    columns: [
      {schema: app, table: users, name: id,    position: 1, data_type: int,     udt_name: int,     nullable: false, default: null, char_max_length: null, numeric_precision: 10, numeric_scale: 0, comment: null, display_type: int}
      {schema: app, table: users, name: email, position: 2, data_type: varchar, udt_name: varchar, nullable: false, default: null, char_max_length: 255, numeric_precision: null, numeric_scale: null, comment: null, display_type: "varchar(255)"}
    ]
    constraints: []
  } | cache write (cache path "mariadb" "mariadb-local-dev__app")
}

# ---- dry-run SQL: MariaDB renders the identical MySQL-dialect SQL --------------

@test
def "dry-run plain select stars all columns" [] {
  fixture
  assert equal (mole-mariadb select --from users -c mariadb-local-dev --dry-run | get query) "SELECT * FROM users"
}

@test
def "dry-run projects filters orders and limits" [] {
  fixture
  assert equal (mole-mariadb select id email --from users --where-sql "age > 30" --sort-by age:desc --limit 5 -c mariadb-local-dev --dry-run | get query) "SELECT id, email FROM users WHERE age > 30 ORDER BY age DESC LIMIT 5"
}

@test
def "dry-run distinct projection" [] {
  fixture
  assert equal (mole-mariadb select status --distinct --from orders -c mariadb-local-dev --dry-run | get query) "SELECT DISTINCT status FROM orders"
}

@test
def "dry-run for-update skip-locked" [] {
  fixture
  assert equal (mole-mariadb select --from orders --lock update --skip-locked -c mariadb-local-dev --dry-run | get query) "SELECT * FROM orders FOR UPDATE SKIP LOCKED"
}

@test
def "dry-run legacy lock in share mode" [] {
  fixture
  assert equal (mole-mariadb select --from orders --where-sql "status = 'pending'" --lock share-mode -c mariadb-local-dev --dry-run | get query) "SELECT * FROM orders WHERE status = 'pending' LOCK IN SHARE MODE"
}

@test
def "dry-run pagination with limit and offset" [] {
  fixture
  assert equal (mole-mariadb select --from users --sort-by id --limit 2 --offset 2 -c mariadb-local-dev --dry-run | get query) "SELECT * FROM users ORDER BY id LIMIT 2 OFFSET 2"
}

@test
def "dry-run predicate tokens compose the WHERE clause" [] {
  fixture
  assert equal (mole-mariadb select id email --from users --where status=active,age>=30 -c mariadb-local-dev --dry-run | get query) "SELECT id, email FROM users WHERE status = 'active' AND age >= 30"
}

@test
def "dry-run IN LIKE and NULL predicate forms in one where token-list" [] {
  fixture
  assert equal (mole-mariadb select --from users --where role=in:admin,ops,name~%acme%,deleted=null -c mariadb-local-dev --dry-run | get query) "SELECT * FROM users WHERE role IN ('admin', 'ops') AND name LIKE '%acme%' AND deleted IS NULL"
}

@test
def "dry-run raw SQL goes in --where-sql and the two flags AND-join" [] {
  fixture
  assert equal (mole-mariadb select --from orders --where-sql "total > 0 AND status <> 'void'" -c mariadb-local-dev --dry-run | get query) "SELECT * FROM orders WHERE total > 0 AND status <> 'void'"
  assert error { mole-mariadb select --from orders --where "a=1 AND b=2" -c mariadb-local-dev --dry-run }   # raw SQL in the token slot errors instead of rendering a = '1 AND b=2'
  assert error { mole-mariadb select --from orders --where "id = 42" -c mariadb-local-dev --dry-run }
  assert equal (mole-mariadb select --from orders --where status=active --where-sql "total > 0 OR legacy" -c mariadb-local-dev --dry-run | get query) "SELECT * FROM orders WHERE (status = 'active') AND (total > 0 OR legacy)"
}

# ---- connection handling ------------------------------------------------------

@test
def "dry-run redacts the password and tags the mariadb driver" [] {
  fixture
  let c = (mole-mariadb select --from users -c mariadb-local-dev --dry-run | get connection)
  assert equal ($c | columns | any {|x| $x == "password"}) false
  assert equal $c.driver "mariadb"
}

@test
def "set-connection rejects a non-mariadb connection" [] {
  fixture
  assert error { mole-mariadb set-connection mysql-local-dev }
}

# ---- flag validation: error paths survived the extraction ---------------------

@test
def "offset without limit errors" [] {
  fixture
  assert error { mole-mariadb select --from users --offset 2 -c mariadb-local-dev --dry-run }
}

@test
def "skip-locked and nowait are mutually exclusive" [] {
  fixture
  assert error { mole-mariadb select --from orders --lock update --skip-locked --nowait -c mariadb-local-dev --dry-run }
}

@test
def "lock-of without lock errors" [] {
  fixture
  assert error { mole-mariadb select --from orders --lock-of t -c mariadb-local-dev --dry-run }
}

@test
def "from is required" [] {
  fixture
  assert error { mole-mariadb select -c mariadb-local-dev --dry-run }
}

# ---- update: dry-run SQL assembly (table is the leading positional) ------------

@test
def "dry-run update sets one column filtered" [] {
  fixture
  assert equal (mole-mariadb update users status=inactive --where-sql "id = 5" -c mariadb-local-dev --dry-run | get query) "UPDATE users SET status = 'inactive' WHERE id = 5"
}

@test
def "dry-run update joins several assignments" [] {
  fixture
  assert equal (mole-mariadb update t a=1 --values-sql {b: "b + 1"} --where-sql "id = 5" -c mariadb-local-dev --dry-run | get query) "UPDATE t SET a = 1, b = b + 1 WHERE id = 5"
}

@test
def "dry-run update with order-by and limit" [] {
  fixture
  assert equal (mole-mariadb update jobs --values-sql {priority: "priority + 1"} --where-sql "queued = 1" --sort-by created_at:asc --limit 100 -c mariadb-local-dev --dry-run | get query) "UPDATE jobs SET priority = priority + 1 WHERE queued = 1 ORDER BY created_at ASC LIMIT 100"
}

@test
def "dry-run update --all allows an unfiltered write" [] {
  fixture
  assert equal (mole-mariadb update users archived=1 --all -c mariadb-local-dev --dry-run | get query) "UPDATE users SET archived = 1"
}

# ---- delete: dry-run SQL assembly (table is the leading positional) ------------

@test
def "dry-run delete filtered" [] {
  fixture
  assert equal (mole-mariadb delete sessions --where-sql "expires_at < now()" -c mariadb-local-dev --dry-run | get query) "DELETE FROM sessions WHERE expires_at < now()"
}

@test
def "dry-run delete with order-by and limit" [] {
  fixture
  assert equal (mole-mariadb delete logs --where-sql "level = 'debug'" --sort-by ts:asc --limit 1000 -c mariadb-local-dev --dry-run | get query) "DELETE FROM logs WHERE level = 'debug' ORDER BY ts ASC LIMIT 1000"
}

@test
def "dry-run delete builds the filter from predicate tokens" [] {
  fixture
  assert equal (mole-mariadb delete sessions --where user_id=7,status=expired -c mariadb-local-dev --dry-run | get query) "DELETE FROM sessions WHERE user_id = 7 AND status = 'expired'"
}


# ---- write verbs: connection handling + safety guards -------------------------

@test
def "dry-run update redacts the password and tags the mariadb driver" [] {
  fixture
  let c = (mole-mariadb update t x=1 --where-sql "id = 1" -c mariadb-local-dev --dry-run | get connection)
  assert equal ($c | columns | any {|x| $x == "password"}) false
  assert equal $c.driver "mariadb"
}

@test
def "update requires at least one assignment" [] {
  fixture
  assert error { mole-mariadb update t --where-sql "id = 1" -c mariadb-local-dev --dry-run }
}

@test
def "update refuses an unfiltered write without --all" [] {
  fixture
  assert error { mole-mariadb update t x=1 -c mariadb-local-dev --dry-run }
  assert error { mole-mariadb update t x=1 --where " " -c mariadb-local-dev --dry-run }   # a blank --where is no filter
  assert error { mole-mariadb delete t --where "," -c mariadb-local-dev --dry-run }            # nor is a bare comma
  assert error { mole-mariadb delete t --where-sql " " -c mariadb-local-dev --dry-run }       # nor a blank raw filter
}

@test
def "delete refuses an unfiltered write without --all" [] {
  fixture
  assert error { mole-mariadb delete t -c mariadb-local-dev --dry-run }
}

# The target table is a REQUIRED leading positional, so omitting it is a parse-time
# error enforced by the signature (`update <table> …` / `delete <table> …`) — not a
# runtime one, so there is nothing catchable to assert here.

# ---- stats: dry-run SQL assembly ----------------------------------------------

@test
def "dry-run stats count and sum per group ordered top-n" [] {
  fixture
  assert equal (mole-mariadb stats --from orders --by region --count --sum amount --sort-by sum_amount:desc --limit 10 -c mariadb-local-dev --dry-run | get query) "SELECT region, count(*) AS count, sum(amount) AS sum_amount FROM orders GROUP BY region ORDER BY sum_amount DESC LIMIT 10"
  assert equal (mole-mariadb stats --from orders --by region --count --sort-by count:desc --limit 2 --offset 1 -c mariadb-local-dev --dry-run | get query) "SELECT region, count(*) AS count FROM orders GROUP BY region ORDER BY count DESC LIMIT 2 OFFSET 1"
}

@test
def "dry-run stats with where and having over result aliases" [] {
  fixture
  assert equal (mole-mariadb stats --from orders --by region,tier --count --avg amount --where status=active --having count>=10 --sort-by avg_amount:desc -c mariadb-local-dev --dry-run | get query) "SELECT region, tier, count(*) AS count, avg(amount) AS avg_amount FROM orders WHERE status = 'active' GROUP BY region, tier HAVING count(*) >= 10 ORDER BY avg_amount DESC"
}

@test
def "dry-run stats grand total distinct count the group-concat dialect aggregate and the offset guard" [] {
  fixture
  assert equal (mole-mariadb stats --from orders --count --sum amount -c mariadb-local-dev --dry-run | get query) "SELECT count(*) AS count, sum(amount) AS sum_amount FROM orders"
  assert equal (mole-mariadb stats --from orders --by region --count-distinct customer_id -c mariadb-local-dev --dry-run | get query) "SELECT region, count(distinct customer_id) AS count_distinct_customer_id FROM orders GROUP BY region"
  assert equal (mole-mariadb stats --from users --by region --group-concat name -c mariadb-local-dev --dry-run | get query) "SELECT region, group_concat(name) AS group_concat_name FROM users GROUP BY region"
  assert equal (mole-mariadb stats --from orders --by region -c mariadb-local-dev --dry-run | get query) "SELECT region, count(*) AS count FROM orders GROUP BY region"
  assert error { mole-mariadb stats --from orders --by region --offset 1 -c mariadb-local-dev --dry-run }   # MariaDB rejects a bare OFFSET
  assert error { mole-mariadb stats -c mariadb-local-dev --dry-run }
}

# Drive a completer through the real engine (completers are private, `@`-bound; see
# DESIGN.md): complete the END of `line` after a `use mole-mariadb` prelude in a child `nu`
# that inherits this test's XDG overrides, and return the candidate values.
def ide-complete [line: string]: nothing -> list<string> {
  let f = (mktemp -t mole-ide.XXXXXX)
  let src = $"use mole-mariadb\n($line)"
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
  assert equal (mole-mariadb insert users email=ann@x.io status=active age=30 zip="01234" deleted=null -c mariadb-local-dev --dry-run | get query) "INSERT INTO users (email, status, age, zip, deleted) VALUES ('ann@x.io', 'active', 30, '01234', NULL)"
  assert equal ([{sku: A1, qty: 3} {sku: B2, qty: 0}] | mole-mariadb insert stock -c mariadb-local-dev --dry-run | get query) "INSERT INTO stock (sku, qty) VALUES ('A1', 3), ('B2', 0)"
  assert equal ({sku: A1, qty: "3"} | mole-mariadb insert stock -c mariadb-local-dev --dry-run | get query) "INSERT INTO stock (sku, qty) VALUES ('A1', '3')"   # a typed string stays a string
  assert equal ([{sku: A1, qty: null}] | mole-mariadb insert stock src=import --values-sql {at: "now()"} -c mariadb-local-dev --dry-run | get query) "INSERT INTO stock (sku, qty, src, at) VALUES ('A1', NULL, 'import', now())"
  assert equal (mole-mariadb insert events kind=login --values-sql {at: "now()"} -c mariadb-local-dev --dry-run | get query) "INSERT INTO events (kind, at) VALUES ('login', now())"
  let r = (mole-mariadb insert t a=1 -c mariadb-local-dev --dry-run)
  assert equal ($r.connection | columns | any {|x| $x == "password"}) false
}

@test
def "insert refuses nothing ragged rows clashes and non-tokens" [] {
  fixture
  assert error { mole-mariadb insert users -c mariadb-local-dev --dry-run }                                           # nothing to insert
  assert error { [{a: 1} {b: 2}] | mole-mariadb insert t -c mariadb-local-dev --dry-run }                             # ragged rows
  assert error { [{a: 1}] | mole-mariadb insert t a=2 -c mariadb-local-dev --dry-run }                                 # piped + token clash
  assert error { mole-mariadb insert t a=1 --values-sql {a: "2"} -c mariadb-local-dev --dry-run }                      # token + expression clash
  assert error { mole-mariadb insert t "a = 1" -c mariadb-local-dev --dry-run }                                       # raw SQL is not a token
  assert error { mole-mariadb insert t "a>=1" -c mariadb-local-dev --dry-run }                                        # a comparison is not one
  assert error { mole-mariadb insert t a==1 -c mariadb-local-dev --dry-run }                                          # operator-looking value
  assert error { mole-mariadb insert t a=1 a=2 -c mariadb-local-dev --dry-run }                                       # duplicate column
}

@test
def "insert escapes backslashes in the mysql dialect" [] {
  fixture
  assert equal (mole-mariadb insert t p='a\b' -c mariadb-local-dev --dry-run | get query) "INSERT INTO t (p) VALUES ('a\\\\b')"
  assert equal ([{p: 'a\b'}] | mole-mariadb insert t -c mariadb-local-dev --dry-run | get query) "INSERT INTO t (p) VALUES ('a\\\\b')"
}

@test
def "dry-run insert ignore upsert in the VALUES form and returning" [] {
  fixture
  assert equal (mole-mariadb insert users email=a@b.c --ignore -c mariadb-local-dev --dry-run | get query) "INSERT IGNORE INTO users (email) VALUES ('a@b.c')"
  assert equal (mole-mariadb insert users email=a@b.c status=active --upsert -c mariadb-local-dev --dry-run | get query) "INSERT INTO users (email, status) VALUES ('a@b.c', 'active') ON DUPLICATE KEY UPDATE email = VALUES(email), status = VALUES(status)"
  assert equal (mole-mariadb insert users email=a@b.c --ignore --returning id,email -c mariadb-local-dev --dry-run | get query) "INSERT IGNORE INTO users (email) VALUES ('a@b.c') RETURNING id, email"
  assert error { mole-mariadb insert users email=a --ignore --upsert -c mariadb-local-dev --dry-run }
}

@test
def "insert completes the unassigned columns of the target table" [] {
  fixture
  seed-schema
  assert equal (ide-complete "mole-mariadb insert -c mariadb-local-dev ") ["app.users"]
  assert equal (ide-complete "mole-mariadb insert app.users -c mariadb-local-dev ") ["email=" "id="]
  assert equal (ide-complete "mole-mariadb insert app.users id=x -c mariadb-local-dev ") ["email="]
  assert equal (ide-complete "mole-mariadb insert app.users id=x -c mariadb-local-dev em") ["email="]
  assert equal (ide-complete "mole-mariadb insert app.users -c mariadb-local-dev id=") []   # a value probe against an unreachable DB yields nothing, never an error
}

# ---- update: the insert assignment grammar -----------------------------------

@test
def "dry-run update renders assignment tokens and values-sql" [] {
  fixture
  assert equal (mole-mariadb update users status=active age=30 zip="01234" note=null --all -c mariadb-local-dev --dry-run | get query) "UPDATE users SET status = 'active', age = 30, zip = '01234', note = NULL"
  assert equal (mole-mariadb update users status=active --values-sql {seen_at: "now()"} --where id=1 -c mariadb-local-dev --dry-run | get query) "UPDATE users SET status = 'active', seen_at = now() WHERE id = 1"
  assert error { mole-mariadb update t "x = 1" --all -c mariadb-local-dev --dry-run }                    # raw SQL is not an assignment token
  assert error { mole-mariadb update t x=1 --values-sql {x: "2"} --all -c mariadb-local-dev --dry-run }   # one column, two values
  assert error { mole-mariadb update t x=1 x=2 --all -c mariadb-local-dev --dry-run }                    # assigned twice
  assert error { mole-mariadb update t --all -c mariadb-local-dev --dry-run }                            # nothing to set
}

@test
def "update completes assignment tokens like insert" [] {
  fixture
  seed-schema
  assert equal (ide-complete "mole-mariadb update app.users -c mariadb-local-dev ") ["email=" "id="]
  assert equal (ide-complete "mole-mariadb update app.users id=x -c mariadb-local-dev ") ["email="]
  assert equal (ide-complete "mole-mariadb update \"app.users u\" -c mariadb-local-dev ") ["email=" "id="]   # an alias is looked up by its base table
}
