use std/assert
use std/testing *
use mole-mysql

# Point mole at a throwaway config holding a mysql + a mariadb connection, so
# `select` can resolve one and render dry-run SQL without a live database (and so
# the cross-driver isolation test has a mariadb connection to be rejected). --env
# so the XDG override lands in the calling test's environment.
def --env fixture [] {
  let d = (mktemp -d)
  mkdir ([$d mole] | path join)
  {connections: {
    mysql:   [{name: mysql-local-dev,   host: "127.0.0.1", port: 3306, user: root, password: secret, database: app}]
    mariadb: [{name: mariadb-local-dev, host: "127.0.0.1", port: 3306, user: root, password: secret, database: app}]
  }}
  | to yaml
  | save --force ([$d mole connections.yaml] | path join)
  $env.XDG_CONFIG_HOME = $d
}

# ---- dry-run SQL assembly: the verb wires the myql renderers correctly ---------

@test
def "dry-run plain select stars all columns" [] {
  fixture
  assert equal (mole-mysql select --from users -c mysql-local-dev --dry-run | get query) "SELECT * FROM users"
}

@test
def "dry-run projects filters orders and limits" [] {
  fixture
  assert equal (mole-mysql select id email --from users --where "age > 30" --sort-by "age desc" --limit 5 -c mysql-local-dev --dry-run | get query) "SELECT id, email FROM users WHERE age > 30 ORDER BY age DESC LIMIT 5"
}

@test
def "dry-run distinct projection" [] {
  fixture
  assert equal (mole-mysql select status --distinct --from orders -c mysql-local-dev --dry-run | get query) "SELECT DISTINCT status FROM orders"
}

@test
def "dry-run group-by with rollup and having" [] {
  fixture
  assert equal (mole-mysql select dept "count(*) AS n" --from employees --group-by [dept] --rollup --having "count(*) > 1" -c mysql-local-dev --dry-run | get query) "SELECT dept, count(*) AS n FROM employees GROUP BY dept WITH ROLLUP HAVING count(*) > 1"
}

@test
def "dry-run for-update skip-locked" [] {
  fixture
  assert equal (mole-mysql select --from orders --lock update --skip-locked -c mysql-local-dev --dry-run | get query) "SELECT * FROM orders FOR UPDATE SKIP LOCKED"
}

@test
def "dry-run legacy lock in share mode" [] {
  fixture
  assert equal (mole-mysql select --from orders --where "status = 'pending'" --lock share-mode -c mysql-local-dev --dry-run | get query) "SELECT * FROM orders WHERE status = 'pending' LOCK IN SHARE MODE"
}

@test
def "dry-run pagination with limit and offset" [] {
  fixture
  assert equal (mole-mysql select --from users --sort-by id --limit 2 --offset 2 -c mysql-local-dev --dry-run | get query) "SELECT * FROM users ORDER BY id LIMIT 2 OFFSET 2"
}

# ---- connection handling ------------------------------------------------------

@test
def "dry-run redacts the password and tags the mysql driver" [] {
  fixture
  let c = (mole-mysql select --from users -c mysql-local-dev --dry-run | get connection)
  assert equal ($c | columns | any {|x| $x == "password"}) false
  assert equal $c.driver "mysql"
}

@test
def "set-connection rejects a non-mysql connection" [] {
  fixture
  assert error { mole-mysql set-connection mariadb-local-dev }
}

# ---- flag validation: error paths survived the extraction ---------------------

@test
def "offset without limit errors" [] {
  fixture
  assert error { mole-mysql select --from users --offset 2 -c mysql-local-dev --dry-run }
}

@test
def "rollup without group-by errors" [] {
  fixture
  assert error { mole-mysql select --from users --rollup -c mysql-local-dev --dry-run }
}

@test
def "skip-locked and nowait are mutually exclusive" [] {
  fixture
  assert error { mole-mysql select --from orders --lock update --skip-locked --nowait -c mysql-local-dev --dry-run }
}

@test
def "lock-of without lock errors" [] {
  fixture
  assert error { mole-mysql select --from orders --lock-of [t] -c mysql-local-dev --dry-run }
}

@test
def "from is required" [] {
  fixture
  assert error { mole-mysql select -c mysql-local-dev --dry-run }
}

# ---- update: dry-run SQL assembly ---------------------------------------------

@test
def "dry-run update sets one column filtered" [] {
  fixture
  assert equal (mole-mysql update "status = 'inactive'" --from users --where "id = 5" -c mysql-local-dev --dry-run | get query) "UPDATE users SET status = 'inactive' WHERE id = 5"
}

@test
def "dry-run update joins several assignments" [] {
  fixture
  assert equal (mole-mysql update "a = 1" "b = b + 1" --from t --where "id = 5" -c mysql-local-dev --dry-run | get query) "UPDATE t SET a = 1, b = b + 1 WHERE id = 5"
}

@test
def "dry-run update with order-by and limit" [] {
  fixture
  assert equal (mole-mysql update "priority = priority + 1" --from jobs --where "queued = 1" --sort-by "created_at asc" --limit 100 -c mysql-local-dev --dry-run | get query) "UPDATE jobs SET priority = priority + 1 WHERE queued = 1 ORDER BY created_at ASC LIMIT 100"
}

@test
def "dry-run update --all allows an unfiltered write" [] {
  fixture
  assert equal (mole-mysql update "archived = 1" --from users --all -c mysql-local-dev --dry-run | get query) "UPDATE users SET archived = 1"
}

# ---- delete: dry-run SQL assembly ---------------------------------------------

@test
def "dry-run delete filtered" [] {
  fixture
  assert equal (mole-mysql delete --from sessions --where "expires_at < now()" -c mysql-local-dev --dry-run | get query) "DELETE FROM sessions WHERE expires_at < now()"
}

@test
def "dry-run delete with order-by and limit" [] {
  fixture
  assert equal (mole-mysql delete --from logs --where "level = 'debug'" --sort-by "ts asc" --limit 1000 -c mysql-local-dev --dry-run | get query) "DELETE FROM logs WHERE level = 'debug' ORDER BY ts ASC LIMIT 1000"
}

# ---- write verbs: connection handling + safety guards -------------------------

@test
def "dry-run update redacts the password and tags the mysql driver" [] {
  fixture
  let c = (mole-mysql update "x = 1" --from t --where "id = 1" -c mysql-local-dev --dry-run | get connection)
  assert equal ($c | columns | any {|x| $x == "password"}) false
  assert equal $c.driver "mysql"
}

@test
def "update requires at least one assignment" [] {
  fixture
  assert error { mole-mysql update --from t --where "id = 1" -c mysql-local-dev --dry-run }
}

@test
def "update refuses an unfiltered write without --all" [] {
  fixture
  assert error { mole-mysql update "x = 1" --from t -c mysql-local-dev --dry-run }
}

@test
def "delete refuses an unfiltered write without --all" [] {
  fixture
  assert error { mole-mysql delete --from t -c mysql-local-dev --dry-run }
}

@test
def "update requires a target table" [] {
  fixture
  assert error { mole-mysql update "x = 1" --where "id = 1" -c mysql-local-dev --dry-run }
}

@test
def "delete requires a target table" [] {
  fixture
  assert error { mole-mysql delete --where "id = 1" -c mysql-local-dev --dry-run }
}
