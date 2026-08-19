use std/assert
use std/testing *
use mole-mariadb

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

# ---- dry-run SQL: MariaDB renders the identical MySQL-dialect SQL --------------

@test
def "dry-run plain select stars all columns" [] {
  fixture
  assert equal (mole-mariadb select --from users -c mariadb-local-dev --dry-run | get query) "SELECT * FROM users"
}

@test
def "dry-run projects filters orders and limits" [] {
  fixture
  assert equal (mole-mariadb select id email --from users --where "age > 30" --sort-by age:desc --limit 5 -c mariadb-local-dev --dry-run | get query) "SELECT id, email FROM users WHERE age > 30 ORDER BY age DESC LIMIT 5"
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
  assert equal (mole-mariadb select --from orders --where "status = 'pending'" --lock share-mode -c mariadb-local-dev --dry-run | get query) "SELECT * FROM orders WHERE status = 'pending' LOCK IN SHARE MODE"
}

@test
def "dry-run pagination with limit and offset" [] {
  fixture
  assert equal (mole-mariadb select --from users --sort-by id --limit 2 --offset 2 -c mariadb-local-dev --dry-run | get query) "SELECT * FROM users ORDER BY id LIMIT 2 OFFSET 2"
}

@test
def "dry-run predicate tokens compose the WHERE clause" [] {
  fixture
  assert equal (mole-mariadb select id email --from users status=active age>=30 -c mariadb-local-dev --dry-run | get query) "SELECT id, email FROM users WHERE status = 'active' AND age >= 30"
}

@test
def "dry-run predicate tokens AND-combine with a raw --where; IN, LIKE, NULL forms" [] {
  fixture
  assert equal (mole-mariadb select --from users role=in:admin,ops name~%acme% deleted=null --where "score > 0" -c mariadb-local-dev --dry-run | get query) "SELECT * FROM users WHERE role IN ('admin', 'ops') AND name LIKE '%acme%' AND deleted IS NULL AND (score > 0)"
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
  assert equal (mole-mariadb update users "status = 'inactive'" --where "id = 5" -c mariadb-local-dev --dry-run | get query) "UPDATE users SET status = 'inactive' WHERE id = 5"
}

@test
def "dry-run update joins several assignments" [] {
  fixture
  assert equal (mole-mariadb update t "a = 1" "b = b + 1" --where "id = 5" -c mariadb-local-dev --dry-run | get query) "UPDATE t SET a = 1, b = b + 1 WHERE id = 5"
}

@test
def "dry-run update with order-by and limit" [] {
  fixture
  assert equal (mole-mariadb update jobs "priority = priority + 1" --where "queued = 1" --sort-by "created_at asc" --limit 100 -c mariadb-local-dev --dry-run | get query) "UPDATE jobs SET priority = priority + 1 WHERE queued = 1 ORDER BY created_at ASC LIMIT 100"
}

@test
def "dry-run update --all allows an unfiltered write" [] {
  fixture
  assert equal (mole-mariadb update users "archived = 1" --all -c mariadb-local-dev --dry-run | get query) "UPDATE users SET archived = 1"
}

# ---- delete: dry-run SQL assembly (table is the leading positional) ------------

@test
def "dry-run delete filtered" [] {
  fixture
  assert equal (mole-mariadb delete sessions --where "expires_at < now()" -c mariadb-local-dev --dry-run | get query) "DELETE FROM sessions WHERE expires_at < now()"
}

@test
def "dry-run delete with order-by and limit" [] {
  fixture
  assert equal (mole-mariadb delete logs --where "level = 'debug'" --sort-by "ts asc" --limit 1000 -c mariadb-local-dev --dry-run | get query) "DELETE FROM logs WHERE level = 'debug' ORDER BY ts ASC LIMIT 1000"
}

@test
def "dry-run delete builds the filter from predicate tokens" [] {
  fixture
  assert equal (mole-mariadb delete sessions user_id=7 status=expired -c mariadb-local-dev --dry-run | get query) "DELETE FROM sessions WHERE user_id = 7 AND status = 'expired'"
}

@test
def "delete rejects an incomplete (operator-less) predicate token" [] {
  fixture
  assert error { mole-mariadb delete sessions foo -c mariadb-local-dev --dry-run }
}

# ---- write verbs: connection handling + safety guards -------------------------

@test
def "dry-run update redacts the password and tags the mariadb driver" [] {
  fixture
  let c = (mole-mariadb update t "x = 1" --where "id = 1" -c mariadb-local-dev --dry-run | get connection)
  assert equal ($c | columns | any {|x| $x == "password"}) false
  assert equal $c.driver "mariadb"
}

@test
def "update requires at least one assignment" [] {
  fixture
  assert error { mole-mariadb update t --where "id = 1" -c mariadb-local-dev --dry-run }
}

@test
def "update refuses an unfiltered write without --all" [] {
  fixture
  assert error { mole-mariadb update t "x = 1" -c mariadb-local-dev --dry-run }
}

@test
def "delete refuses an unfiltered write without --all" [] {
  fixture
  assert error { mole-mariadb delete t -c mariadb-local-dev --dry-run }
}

# The target table is a REQUIRED leading positional, so omitting it is a parse-time
# error enforced by the signature (`update <table> …` / `delete <table> …`) — not a
# runtime one, so there is nothing catchable to assert here.
