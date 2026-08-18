# mole-mariadb — MariaDB driver plugin.
#
# A PLUGIN (data source): registers the `mariadb` driver and exposes the user
# verbs `raw-query` / `select` / `schema` / `set-connection`. SIBLING of
# mole-mysql: MariaDB speaks the MySQL wire protocol and the MySQL dialect, so the
# two drivers share everything dialect-shaped through mole-myql (information_schema
# SQL, clause renderers, the tinyint(1)→bool + numeric/date coercions) and the
# generic mole-sql. The layers:
#   - mole core plumbing        (`use mole/lib/*.nu`)      — conn / cache / query
#   - the generic SQL library   (`use mole-sql/sql.nu`)    — assemble, typing, schema helpers
#   - the MySQL-dialect library (`use mole-myql/myql.nu`)  — information_schema SQL, clause renderers, coercions
#
# What THIS driver owns — the genuine ENGINE divergences from mole-mysql:
#   - the client binary — `^mariadb`, not `^mysql`. Modern MariaDB packages ship
#     the `mariadb` client and no longer guarantee the legacy `mysql` symlink, so a
#     MariaDB-only host connects with this driver. It is a drop-in for the mysql
#     client: same flags, same MYSQL_PWD, same batch → TSV output.
#   - the JSON policy — MariaDB's `JSON` is an ALIAS for `LONGTEXT`, so
#     information_schema reports `data_type = longtext` and a JSON column is
#     indistinguishable from plain text. `ma-type` therefore leaves it a string
#     (parse it yourself with `from json`); it does NOT get MySQL's native-`json`
#     auto-parse. This one divergence is the whole reason mole-mysql and mole-mariadb
#     are separate drivers rather than one with a binary fallback.
# Everything else — resolve → exec → check → parse → cache → type — is the same
# shape as mole-mysql.

use mole/lib/conn.nu

# Driver-scoped connection completer: only THIS driver (mariadb), never other drivers.
def "complete-connection" []: nothing -> list<string> { conn names "mariadb" }
use mole/lib/cache.nu
use mole/lib/query.nu
use mole/lib/complete.nu
use mole-sql/sql.nu
use mole-myql/myql.nu

export-env {
  conn register "mariadb"
}

# ---- engine specifics (mariadb) -----------------------------------------------

# Run one SQL statement, returning a `complete` record. Query on stdin (batch
# mode → tab-separated output); password via MYSQL_PWD. The `mariadb` client is a
# drop-in for `mysql` — identical flags and env.
def ma-exec [conf: record, sql: string]: nothing -> record {
  let db = ($conf | get -o database)
  let db_args = if ($db | is-not-empty) { ["-D" $db] } else { [] }
  with-env { MYSQL_PWD: ($conf | get -o password | default "") } {
    $sql | ^mariadb -u $conf.user -h $conf.host -P ($conf | get -o port | default 3306) ...$db_args | complete
  }
}

# Exec + check + lossless parse (every cell stays a string).
def ma-rows [conf: record, sql: string]: nothing -> any {
  ma-exec $conf $sql | query check | from tsv --no-infer
}

# data_type → cell-converter closure (or null). MariaDB shares MySQL's coercions
# (tinyint(1)→bool, the numeric and date families) via `myql cell-type` and adds
# NOTHING on top: its `JSON` type is a LONGTEXT alias — indistinguishable from text
# in information_schema — so JSON columns stay strings (parse with `from json`).
def ma-type [col: record]: nothing -> any { myql cell-type $col }

# ---- orchestration ------------------------------------------------------------

# Load the schema cache for a connection, rebuilding when --refresh or stale.
def ma-schema-load [conf: record, --refresh]: nothing -> record {
  let db = ($conf | get -o database | default "_")
  let file = (cache path "mariadb" $"($conf.name)__($db)")
  if $refresh or (cache stale $file 1day) {
    let secs = [
        {k: "tables"      q: (myql tables-sql)}
        {k: "columns"     q: (myql columns-sql)}
        {k: "constraints" q: (myql constraints-sql)}
      ]
      | par-each {|s| {key: $s.k, rows: (ma-rows $conf $s.q)} }
      | reduce --fold {} {|it, acc| $acc | upsert $it.key $it.rows }
    let body = (sql schema-body $secs.tables $secs.columns $secs.constraints {|c| myql display-type $c } (myql nulls))
    let data = ({meta: {connection: $conf.name, database: $db, driver: "mariadb", refreshed_at: (date now)}} | merge $body)
    $data | cache write $file
    return $data
  }
  cache read $file
}

# The standard override record: named flags win over the resolved connection,
# and --set wins over the named flags (for arbitrary/driver-specific fields).
def ma-conf [
  connection: any, host: any, port: any,
  user: any, password: any, database: any, set: record
]: nothing -> record {
  conn with mariadb $connection ({
    host: $host, port: $port,
    user: $user, password: $password, database: $database
  } | merge $set)
}

# ---- completers (cache-backed; build the schema on a cache miss) --------------
# These call ma-schema-load, so a first completion against a not-yet-cached (or
# day-stale) connection introspects the live DB once, then serves from cache.

def mariadb-catalog [context: string]: nothing -> record {
  complete catalog-ctx $context mariadb --get {|c| ma-schema-load $c }
}

def "mariadb-table" [context: string]: nothing -> list<string> {
  sql complete-tables (mariadb-catalog $context)
}

# Comma-list variant for the `schema --include/--exclude` filters: re-prepend the
# already-typed tables so accepting a candidate extends the list.
def "mariadb-tables-csv" [context: string]: nothing -> list<string> {
  let prefix = (complete token $context | str replace --regex '[^,]*$' '')
  sql complete-tables (mariadb-catalog $context) | each {|t| $"($prefix)($t)" }
}

def "mariadb-column" [context: string]: nothing -> list<string> {
  # `select` names its table with --from; `update`/`delete` take it as the leading
  # positional — fall back to that so column completion works for the write verbs too.
  let tbl = (complete flag $context [--from -F] | default (sql lead-arg $context [update delete]))
  sql complete-columns (mariadb-catalog $context) $tbl
}

# Comma-list variant of `mariadb-column` for the multi-value `--group-by` flag:
# re-prepend the already-typed columns so accepting a candidate extends the list
# (Nushell can't complete inside a `[...]` list literal).
def "mariadb-columns-csv" [context: string]: nothing -> list<string> {
  let prefix = (complete token $context | str replace --regex '[^,]*$' '')
  mariadb-column $context | each {|c| $"($prefix)($c)" }
}

# Completion-only bounded/quiet distinct-value probe: a read-only SELECT run with a
# short connect timeout and MariaDB's per-statement `SET STATEMENT max_statement_time`
# (seconds), returning the `v` column's values (empty on any non-zero exit). Separate
# from `ma-exec` so the verbs are untouched; the caller wraps it in `try`.
def ma-probe [conf: record, sql: string]: nothing -> list<string> {
  let db = ($conf | get -o database)
  let db_args = if ($db | is-not-empty) { ["-D" $db] } else { [] }
  let bounded = ("SET STATEMENT max_statement_time=3 FOR " + $sql)
  let r = (with-env { MYSQL_PWD: ($conf | get -o password | default "") } {
    $bounded | ^mariadb --connect-timeout=3 -u ($conf | get -o user) -h ($conf | get -o host) -P ($conf | get -o port | default 3306) ...$db_args | complete
  })
  if ($r.exit_code != 0) { return [] }
  $r.stdout | from tsv --no-infer | get -o v | default []
}

# Completer for the rest slot that holds BOTH projections and `col<op>value`
# predicate tokens (`select`'s ...columns, `delete`'s ...predicates). A BARE token
# completes column names (like `mariadb-column`). An `=`/`!=` token runs a LIVE,
# bounded `SELECT DISTINCT <col>` — scoped to the sibling predicates and `--from`
# table already on the line — and offers `col<op>value` for each distinct value
# (best-effort: unreachable/slow/errored → no candidates). Comparison/LIKE/`in:`
# tokens complete nothing; a distinct value with spaces/quotes may need manual
# quoting when accepted.
def "mariadb-arg" [context: string]: nothing -> list<string> {
  let p = (sql predicate-token (complete token $context))
  if ($p == null) { return (mariadb-column $context) }
  if ($p.op not-in ["=" "!="]) or ($p.value | str starts-with "in:") { return [] }
  let table = (complete flag $context [--from -F] | default (sql lead-arg $context [update delete]))
  let conf = (complete conn-ctx $context "mariadb")
  if ($table | is-empty) or ($conf | is-empty) { return [] }
  let siblings = (sql split-args (complete positionals $context) | get predicates | where col != $p.col)
  # The probe SELECT frame (incl. LIMIT) is the driver's — mole-sql only composes the WHERE.
  let where = (sql build-where $siblings --dialect (myql dialect))
  let q = (sql assemble [
    $"SELECT DISTINCT ($p.col) AS v FROM ($table)"
    (if ($where | is-not-empty) { $"WHERE ($where)" })
    "LIMIT 50"
  ])
  (try { ma-probe $conf $q } catch { [] }) | each {|v| $p.col + $p.op + $v }
}

def "mariadb-lock" [context: string]: nothing -> list<string> { myql lock-modes }

# ---- user verbs ---------------------------------------------------------------

# Run an arbitrary SQL statement against a MariaDB connection.
#
# The statement text is the positional <sql>, a saved `--file` (resolved under
# the query dir with a `.sql` suffix), or `$EDITOR` when neither is given. Cells
# come back LOSSLESS — every value is the string `mariadb` printed in its
# tab-separated batch output, uncoerced (use `select` when you want DB-typed
# rows). A statement matching the dialect danger regex (writes, DDL, grants, …)
# prompts for confirmation first, which `--yes` skips. The connection is the
# current mariadb one unless `--connection` names another; per-field flags and
# `--set` override individual fields.
#
# Named `raw-query`, not `run`, because `run` is a Nushell parser keyword. Reference
# invocations (leaf verb — call it as your loader exposes it, e.g. `mole-mariadb raw-query`):
#
#   mole-mariadb raw-query "SELECT now()"                                    # the current connection
#   mole-mariadb raw-query "SELECT id, email FROM users ORDER BY id" -c mariadb-local-dev
#   mole-mariadb raw-query --file reports/active-users -c mariadb-local-dev  # <querydir>/reports/active-users.sql
#   mole query show reports/active-users.sql | mole-mariadb raw-query -c mariadb-local-dev  # query text piped via stdin
#   mole-mariadb raw-query "CREATE TEMPORARY TABLE t (id int)" -c mariadb-local-dev --yes   # skip the danger prompt
@category mole-mariadb
export def "raw-query" [
  sql?: string                                     # SQL statement (else --file, else stdin, else $EDITOR)
  --file(-f): string@"complete queryfile"          # saved query file (relative to the query dir)
  --connection(-c): string@complete-connection   # named connection (default: current)
  --host(-h): string                               # override host
  --port(-p): int                                  # override port
  --user(-u): string                               # override user
  --password(-P): string                           # override password
  --database(-d): string                           # override database
  --set: record = {}                               # override any other connection field(s)
  --yes(-y)                                         # skip the dangerous-query prompt
] {
  let conf = (ma-conf $connection $host $port $user $password $database $set)
  let text = ($in | query resolve $sql --file $file --suffix ".sql")
  if (query is-dangerous $text (myql dangerous)) and (not (query confirm "This query may modify data. Run it?" --yes=$yes)) {
    return
  }
  ma-rows $conf $text
}

# Compose and run a single-table MariaDB SELECT, returning DB-typed rows.
#
# Every clause body — the projected columns, `--where`, `--having`, `--group-by`
# keys, `--sort-by` terms — is passed to mariadb VERBATIM, so expressions like
# `count(*)`, `json_extract(x,'$.k')` all work; you quote reserved identifiers
# yourself. There is NO join support: the query always reads the single `--from`
# table.
#
# A positional token shaped `col<op>value` (`status=active`, `age>=30`,
# `name~%acme%`, `role=in:admin,ops`, `deleted=null`) is composed into the WHERE
# clause — AND-joined, and AND-combined with any raw `--where` — with its column
# name tab-completing. Operators are `= != > >= < <=`, `~`/`!~` (LIKE / NOT LIKE),
# and the `=null` / `=in:` forms; the value is quoted by shape (numbers/bools bare,
# else a string literal). Bare tokens stay projected columns. Anything the grammar
# can't express (an expression RHS like `now()`, `OR`, a sub-select) goes in
# `--where`. Flags render the mysql-dialect frame around the clause bodies:
# `GROUP BY ... WITH ROLLUP` (`--rollup`), and the locks
# `FOR UPDATE|SHARE [OF ...] [SKIP LOCKED|NOWAIT]` plus the legacy
# `LOCK IN SHARE MODE` (`--lock share-mode`). MariaDB has no `NULLS FIRST|LAST` and
# rejects a bare `OFFSET`, so `--offset` requires `--limit`.
#
# Only the `--from` table's cached columns are DB-typed (tinyint(1)→bool, int,
# decimal, date/datetime → real nu values); a JSON column stays a STRING because
# MariaDB stores JSON as LONGTEXT (parse it with `from json` yourself). Computed
# and aliased columns stay strings too, but SQL NULLs are normalized to `null`
# across every column (so a NULL reads the same here as on Postgres, not `"NULL"`
# vs `""`). Pass `--raw` for the untouched, fully lossless rows (no typing, no
# null-normalization). `--dry-run` returns a `{connection, query}` record — the
# resolved connection (secrets dropped) and the assembled SQL — without running
# it. A `--lock` clause locks the matched rows, so it prompts unless you pass
# `--yes`. Connection is overridable via `--connection` + per-field flags /
# `--set`, as in `raw-query`.
@category mole-mariadb
@example "every column of a table" {
  mole-mariadb select --from users --dry-run | get query
} --result "SELECT * FROM users"
@example "project, filter, order and limit" {
  mole-mariadb select id email --from users --where "age > 30" --sort-by "age desc" --limit 5 --dry-run | get query
} --result "SELECT id, email FROM users WHERE age > 30 ORDER BY age DESC LIMIT 5"
@example "DISTINCT" {
  mole-mariadb select status --distinct --from orders --dry-run | get query
} --result "SELECT DISTINCT status FROM orders"
@example "aggregate with GROUP BY and HAVING" {
  mole-mariadb select user_id "count(*) AS n" --from orders --group-by user_id --having "count(*) > 1" --sort-by "n desc" --dry-run | get query
} --result "SELECT user_id, count(*) AS n FROM orders GROUP BY user_id HAVING count(*) > 1 ORDER BY n DESC"
@example "GROUP BY ... WITH ROLLUP — subtotal + grand-total rows" {
  mole-mariadb select dept "count(*) AS n" --from employees --group-by dept --rollup --dry-run | get query
} --result "SELECT dept, count(*) AS n FROM employees GROUP BY dept WITH ROLLUP"
@example "multi-key ORDER BY" {
  mole-mariadb select name salary --from employees --sort-by "salary desc, name asc" --dry-run | get query
} --result "SELECT name, salary FROM employees ORDER BY salary DESC, name ASC"
@example "pagination with LIMIT + OFFSET (OFFSET requires LIMIT)" {
  mole-mariadb select --from users --sort-by id --limit 2 --offset 2 --dry-run | get query
} --result "SELECT * FROM users ORDER BY id LIMIT 2 OFFSET 2"
@example "shared read lock: LOCK IN SHARE MODE" {
  mole-mariadb select --from orders --where "status = 'pending'" --lock share-mode --dry-run | get query
} --result "SELECT * FROM orders WHERE status = 'pending' LOCK IN SHARE MODE"
@example "row lock: FOR UPDATE SKIP LOCKED (needs --yes to run for real)" {
  mole-mariadb select --from orders --lock update --skip-locked --dry-run | get query
} --result "SELECT * FROM orders FOR UPDATE SKIP LOCKED"
@example "extract JSON verbatim (the column stays a string on MariaDB)" {
  mole-mariadb select sku "json_extract(attrs, '$.color') AS color" --from products --dry-run | get query
} --result "SELECT sku, json_extract(attrs, '$.color') AS color FROM products"
@example "predicate tokens compose the WHERE clause (columns complete)" {
  mole-mariadb select id email --from users status=active age>=30 --dry-run | get query
} --result "SELECT id, email FROM users WHERE status = 'active' AND age >= 30"
@example "IN, LIKE and NULL predicate forms, AND-combined with a raw --where" {
  mole-mariadb select --from users role=in:admin,ops name~%acme% deleted=null --where "score > 0" --dry-run | get query
} --result "SELECT * FROM users WHERE role IN ('admin', 'ops') AND name LIKE '%acme%' AND deleted IS NULL AND (score > 0)"
@example "run for real — tinyint(1)→bool, decimal→float (JSON stays a string)" {
  mole-mariadb select sku in_stock price tags --from products --sort-by id -c mariadb-local-dev
}
export def "select" [
  ...columns: string@"mariadb-arg"                 # projected columns, or `col<op>value` predicate tokens (default: *)
  --from(-F): string@"mariadb-table"               # source table, single table only (an alias is allowed: "users u")
  --where(-w): string                              # raw WHERE predicate, AND-combined with any col<op>value tokens
  --group-by(-g): string@"mariadb-columns-csv"     # GROUP BY keys, comma-separated
  --rollup                                         # append WITH ROLLUP to GROUP BY
  --having: string                                 # HAVING predicate (without the keyword)
  --sort-by(-s): string                            # ORDER BY terms, comma-separated: "col [asc|desc]"
  --limit(-l): int                                 # LIMIT N
  --offset(-o): int                                # OFFSET N (requires --limit)
  --distinct                                       # SELECT DISTINCT
  --lock: string@"mariadb-lock"                    # row lock: update | share | share-mode (LOCK IN SHARE MODE)
  --lock-of: string@"mariadb-tables-csv"           # FOR ... OF <tables>, comma-separated (update/share only)
  --skip-locked                                    # locking wait policy (update/share only)
  --nowait                                         # locking wait policy (update/share only)
  --connection(-c): string@complete-connection   # named connection (default: current)
  --host(-h): string
  --port(-p): int
  --user(-u): string
  --password(-P): string
  --database(-d): string
  --set: record = {}
  --raw(-R)                                         # raw driver output: no typing, no null-normalization
  --dry-run(-n)                                    # return a {connection, query} record instead of running
  --yes(-y)                                         # skip the lock-confirmation prompt (with --lock)
] {
  # Multi-value flags arrive as ONE comma-joined string (Nushell can't complete inside a
  # `[...]` literal); decode to the list the clause renderers want, shadowing the params.
  let group_by = (sql csv-split $group_by)
  let lock_of = (sql csv-split $lock_of)
  if $skip_locked and $nowait {
    error make {msg: "select: --skip-locked and --nowait are mutually exclusive"}
  }
  if (($lock | is-empty)) and (($lock_of | is-not-empty) or $skip_locked or $nowait) {
    error make {msg: "select: --lock-of/--skip-locked/--nowait require --lock"}
  }
  if (($lock | default "" | str lowercase) == "share-mode") and (($lock_of | is-not-empty) or $skip_locked or $nowait) {
    error make {msg: "select: --lock share-mode (LOCK IN SHARE MODE) takes no --lock-of/--skip-locked/--nowait; use --lock share"}
  }
  if ($rollup) and (($group_by | default []) | is-empty) {
    error make {msg: "select: --rollup requires --group-by"}
  }
  if ($offset != null) and ($limit == null) {
    error make {msg: "select: --offset requires --limit (MariaDB rejects a bare OFFSET)"}
  }
  if ($from | is-empty) { error make {msg: "select: --from <table> is required"} }
  # Split the rest slot: bare tokens are projections, `col<op>value` tokens are WHERE
  # predicates, AND-combined with the raw --where.
  let parts = (sql split-args $columns)
  let where_sql = (sql build-where $parts.predicates --raw ($where | default "") --dialect (myql dialect))
  let group_frag = (sql join-list ($group_by | default []) --prefix "GROUP BY ")
  let group_frag = if ($group_frag != null) and $rollup { $group_frag + " WITH ROLLUP" } else { $group_frag }
  let text = (sql assemble [
    (myql projection $parts.projections $distinct)
    $"FROM ($from)"
    (if ($where_sql | is-not-empty) { $"WHERE ($where_sql)" })
    $group_frag
    (if ($having | is-not-empty) { $"HAVING ($having)" })
    (myql order $sort_by)
    (if $limit != null { $"LIMIT ($limit)" })
    (if $offset != null { $"OFFSET ($offset)" })
    (myql lock $lock ($lock_of | default []) $skip_locked $nowait)
  ])
  let conf = (ma-conf $connection $host $port $user $password $database $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  # A composed SELECT can only ever read — the sole side effect it can carry is a
  # row lock, so gate the prompt on that, not on scanning the user's clause bodies.
  if ($lock | is-not-empty) and (not (query confirm "This locks the matched rows. Run it?" --yes=$yes)) {
    return
  }
  let rows = (ma-rows $conf $text)
  if $raw { return $rows }
  $rows
  | sql normalize-nulls (myql nulls)
  | sql apply-types (sql columns-for (ma-schema-load $conf) (sql base-table $from)) {|c| ma-type $c }
}

# Compose and run a single-table MariaDB UPDATE.
#
# Reads like the statement: `update <table> <assignment>...`. The table is the
# leading positional (completing table names); the SET assignments follow as
# positionals — each a verbatim `"col = expr"`, so expressions (`hits = hits + 1`,
# `updated_at = now()`) all work; you quote identifiers and string literals
# yourself, and their column names complete against the table. `--where` is the
# same verbatim predicate as `select`. MariaDB scopes a single-table UPDATE with an
# optional `ORDER BY ... LIMIT` (`--sort-by` / `--limit`) — the bounded-rewrite
# idiom; there is NO RETURNING and NO join support (reach for `raw-query` for
# multi-table updates).
#
# UPDATE always writes, so it prompts before running (skip with `--yes`) and
# REFUSES to touch every row unless you pass `--all` (a missing `--where` would
# otherwise rewrite the whole table). `--dry-run` returns a `{connection, query}`
# record without running. Connection overridable via `--connection` + per-field
# flags / `--set`, as in `raw-query`.
@category mole-mariadb
@example "set a column on the matched rows" {
  mole-mariadb update users "status = 'inactive'" --where "id = 5" --dry-run | get query
} --result "UPDATE users SET status = 'inactive' WHERE id = 5"
@example "several assignments at once" {
  mole-mariadb update users "status = 'active'" "verified = 1" --where "email = 'a@b.c'" --dry-run | get query
} --result "UPDATE users SET status = 'active', verified = 1 WHERE email = 'a@b.c'"
@example "bounded rewrite: ORDER BY ... LIMIT" {
  mole-mariadb update jobs "priority = priority + 1" --where "queued = 1" --sort-by "created_at asc" --limit 100 --dry-run | get query
} --result "UPDATE jobs SET priority = priority + 1 WHERE queued = 1 ORDER BY created_at ASC LIMIT 100"
@example "guard: an unfiltered UPDATE needs --all" {
  mole-mariadb update users "archived = 1" --all --dry-run | get query
} --result "UPDATE users SET archived = 1"
export def "update" [
  table: string@"mariadb-table"                    # target table (UPDATE <table>); single table, an alias is allowed: "users u"
  ...assignments: string@"mariadb-column"          # SET assignments, verbatim "col = expr" (at least one required)
  --where(-w): string                              # WHERE predicate (without the keyword)
  --sort-by(-s): string                            # ORDER BY terms, comma-separated: "col [asc|desc]" (with --limit)
  --limit(-l): int                                 # LIMIT N — cap the rows changed
  --all                                            # allow an unfiltered UPDATE (every row) when --where is omitted
  --connection(-c): string@complete-connection   # named connection (default: current)
  --host(-h): string
  --port(-p): int
  --user(-u): string
  --password(-P): string
  --database(-d): string
  --set: record = {}
  --dry-run(-n)                                    # return a {connection, query} record instead of running
  --yes(-y)                                         # skip the confirmation prompt
] {
  if ($assignments | is-empty) { error make {msg: "update: at least one SET assignment is required, e.g. update users \"status = 'active'\""} }
  if ($where | is-empty) and (not $all) {
    error make {msg: "update: refusing to update every row without --where (pass --all to override)"}
  }
  let text = (sql assemble [
    (sql build-update --table $table --set $assignments --where ($where | default ""))
    (myql order $sort_by)
    (if $limit != null { $"LIMIT ($limit)" })
  ])
  let conf = (ma-conf $connection $host $port $user $password $database $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (not (query confirm "This UPDATE will modify rows. Run it?" --yes=$yes)) { return }
  ma-rows $conf $text
}

# Compose and run a single-table MariaDB DELETE.
#
# Reads like the statement: `delete <table> <predicate>...`. The table is the
# leading positional (completing table names); the `col<op>value` predicate tokens
# (`user_id=7`, `status=inactive`, `role=in:a,b`) are AND-joined into the WHERE
# clause, their column names completing — the same grammar as `select`. `--where`
# is the raw escape (for an expression RHS like `now()`, `OR`, a sub-select),
# AND-combined with the tokens. Like UPDATE, MariaDB scopes a single-table DELETE
# with an optional `ORDER BY ... LIMIT` (`--sort-by` / `--limit`) — delete the
# "oldest N" and so on. There is NO RETURNING and NO join support (reach for
# `raw-query` for `DELETE ... USING`/multi-table).
#
# DELETE always writes, so it prompts before running (skip with `--yes`) and
# REFUSES to delete every row unless you pass `--all`. `--dry-run` returns a
# `{connection, query}` record without running. Connection overridable as in
# `raw-query`.
@category mole-mariadb
@example "predicate tokens build the filter (columns complete)" {
  mole-mariadb delete sessions user_id=7 --dry-run | get query
} --result "DELETE FROM sessions WHERE user_id = 7"
@example "an expression filter uses the raw --where" {
  mole-mariadb delete sessions --where "expires_at < now()" --dry-run | get query
} --result "DELETE FROM sessions WHERE expires_at < now()"
@example "delete the oldest N (ORDER BY ... LIMIT)" {
  mole-mariadb delete logs --where "level = 'debug'" --sort-by "ts asc" --limit 1000 --dry-run | get query
} --result "DELETE FROM logs WHERE level = 'debug' ORDER BY ts ASC LIMIT 1000"
@example "guard: an unfiltered DELETE needs --all" {
  mole-mariadb delete staging_rows --all --dry-run | get query
} --result "DELETE FROM staging_rows"
export def "delete" [
  table: string@"mariadb-table"                    # target table (DELETE FROM <table>); single table, an alias is allowed: "users u"
  ...predicates: string@"mariadb-arg"              # `col<op>value` filter tokens (AND-joined): user_id=7  status=inactive  role=in:a,b
  --where(-w): string                              # raw WHERE predicate, AND-combined with any predicate tokens
  --sort-by(-s): string                            # ORDER BY terms, comma-separated: "col [asc|desc]" (with --limit)
  --limit(-l): int                                 # LIMIT N — cap the rows removed
  --all                                            # allow an unfiltered DELETE (every row) when --where is omitted
  --connection(-c): string@complete-connection   # named connection (default: current)
  --host(-h): string
  --port(-p): int
  --user(-u): string
  --password(-P): string
  --database(-d): string
  --set: record = {}
  --dry-run(-n)                                    # return a {connection, query} record instead of running
  --yes(-y)                                         # skip the confirmation prompt
] {
  let parts = (sql split-args $predicates)
  if ($parts.projections | is-not-empty) {
    error make {msg: ("delete: incomplete predicate(s): " + ($parts.projections | str join ", ") + " — use col=value, col>=value, col~pattern, col=in:a,b or col=null")}
  }
  let where_sql = (sql build-where $parts.predicates --raw ($where | default "") --dialect (myql dialect))
  if ($where_sql | is-empty) and (not $all) {
    error make {msg: "delete: refusing to delete every row without a filter (pass --all to override)"}
  }
  let text = (sql assemble [
    (sql build-delete --table $table --where ($where_sql | default ""))
    (myql order $sort_by)
    (if $limit != null { $"LIMIT ($limit)" })
  ])
  let conf = (ma-conf $connection $host $port $user $password $database $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (not (query confirm "This DELETE will remove rows. Run it?" --yes=$yes)) { return }
  ma-rows $conf $text
}

# Inspect a connection's cached schema (introspection is cached for a day).
#
# The default view is one summary row per table: schema, name, type, column
# count, primary key, row estimate, comment. `--table` switches to the full
# detail for one table (its columns and constraints); `--find` searches table and
# column names and comments case-insensitively; `--full` returns the raw cache
# record, including its `meta`. `--refresh` rebuilds the cache from the live
# database before reading. `--include`/`--exclude` (mutually exclusive) narrow the
# tables shown in EVERY view (comma-separated names — bare or `schema.`-qualified,
# `*` globs allowed);
# excluding a table also drops any foreign key that pointed at it, so a filtered
# `--full` feeds `mole-mermaid` a clean diagram of just the tables you want.
# Connection is overridable exactly as in `run`.
@category mole-mariadb
@example "summary — one row per table" {
  mole-mariadb schema -c mariadb-local-dev
}
@example "detail for one table (its columns + constraints)" {
  mole-mariadb schema --table users -c mariadb-local-dev
}
@example "search names and comments for 'balance'" {
  mole-mariadb schema --find balance -c mariadb-local-dev
}
@example "rebuild the cache from the live database first" {
  mole-mariadb schema --refresh -c mariadb-local-dev
}
@example "the raw cache record, including meta" {
  mole-mariadb schema --full -c mariadb-local-dev
}
@example "render only the core tables as a Mermaid ER diagram" {
  mole-mariadb schema --full --include "users,orders,order_items" -c mariadb-local-dev | mole-mermaid er-schema
}
@example "dump everything except housekeeping tables" {
  mole-mariadb schema --full --exclude "*_audit,django_*" -c mariadb-local-dev
}
export def "schema" [
  --connection(-c): string@complete-connection   # named connection (default: current)
  --table(-t): string@"mariadb-table"              # detail view for one table
  --find: string                                   # find tables/columns by name or comment (case-insensitive)
  --refresh(-r)                                    # rebuild the cache before reading
  --full                                           # return the full cache record
  --include: string@"mariadb-tables-csv"           # keep ONLY these tables — comma-sep names/globs (mutually exclusive with --exclude)
  --exclude: string@"mariadb-tables-csv"           # drop these tables — comma-sep names/globs (mutually exclusive with --include)
  --host(-h): string                               # override host
  --port(-p): int                                  # override port
  --user(-u): string                               # override user
  --password(-P): string                           # override password
  --database(-d): string                           # override database
  --set: record = {}                               # override any other connection field(s)
] {
  if ($include | is-not-empty) and ($exclude | is-not-empty) {
    error make {msg: "schema: --include and --exclude are mutually exclusive"}
  }
  let conf = (ma-conf $connection $host $port $user $password $database $set)
  let data = (sql schema-filter (ma-schema-load $conf --refresh=$refresh) --include (sql csv-split $include) --exclude (sql csv-split $exclude))
  if $full { return $data }
  if ($find | is-not-empty) {
    sql schema-find $data $find
  } else if ($table | is-not-empty) {
    sql schema-detail $data $table
  } else {
    sql schema-tables $data
  }
}

# Make a mariadb connection the current one for this driver.
#
# Records the choice in `$env.MOLE_CURRENT.mariadb`, so later `run` / `select` /
# `schema` calls can omit `--connection`. Validates that `name` exists and is
# actually a mariadb connection (errors otherwise). Being `--env`, the change
# persists in the caller's environment.
@category mole-mariadb
@example "make the local dev database current" {
  mole-mariadb set-connection mariadb-local-dev
}
export def --env "set-connection" [
  name: string@complete-connection   # a mariadb connection name (from the connections file)
]: nothing -> nothing {
  conn set-current mariadb $name | ignore
}
