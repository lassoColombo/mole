# mole-mysql — MySQL driver plugin.
#
# A PLUGIN (data source): registers the `mysql` driver and exposes the user verbs
# `raw-query` / `select` / `schema` / `set-connection`. It composes three layers:
#   - mole core plumbing        (`use mole/lib/*.nu`)      — conn / cache / query
#   - the generic SQL library   (`use mole-sql/sql.nu`)    — assemble, typing, schema helpers
#   - the MySQL-dialect library (`use mole-myql/myql.nu`)  — information_schema SQL, clause renderers, coercions
#
# This driver is DELIBERATELY THIN: all it owns is what is genuinely MySQL-the-
# ENGINE specific, as opposed to MySQL-the-DIALECT (which it shares with its
# sibling mole-mariadb through mole-myql):
#   - the client binary — `^mysql` over the MySQL wire protocol (stdin batch → TSV,
#     password via MYSQL_PWD);
#   - the JSON policy — MySQL has a native `json` type, so `my-type` parses it.
#     (MariaDB's `JSON` is a LONGTEXT alias, indistinguishable from text, so it
#     stays a string — that one divergence is the whole reason for two drivers.)
# Orchestration (resolve → exec → check → parse → cache → type) has the same shape
# as its sibling; only these private engine pieces differ.

use mole/lib/conn.nu

# Driver-scoped connection completer: only THIS driver (mysql), never other drivers.
def "complete-connection" []: nothing -> list<string> { conn names "mysql" }
use mole/lib/cache.nu
use mole/lib/query.nu
use mole/lib/complete.nu
use mole-sql/sql.nu
use mole-myql/myql.nu

export-env {
  conn register "mysql"
}

# ---- engine specifics (mysql) -------------------------------------------------

# Run one SQL statement, returning a `complete` record. Query on stdin (batch
# mode → tab-separated output); password via MYSQL_PWD.
def my-exec [conf: record, sql: string]: nothing -> record {
  let db = ($conf | get -o database)
  let db_args = if ($db | is-not-empty) { ["-D" $db] } else { [] }
  with-env { MYSQL_PWD: ($conf | get -o password | default "") } {
    $sql | ^mysql -u $conf.user -h $conf.host -P ($conf | get -o port | default 3306) ...$db_args | complete
  }
}

# Exec + check + lossless parse (every cell stays a string).
def my-rows [conf: record, sql: string]: nothing -> any {
  my-exec $conf $sql | query check | from tsv --no-infer
}

# data_type → cell-converter closure (or null to leave the column as-is). The
# coercions shared with MariaDB come from `myql cell-type` (tinyint(1)→bool, the
# numeric and date families); MySQL's native `json` type is parsed HERE — its one
# typing divergence from MariaDB.
def my-type [col: record]: nothing -> any {
  let base = (myql cell-type $col)
  if $base != null { return $base }
  if (($col | get -o data_type) == "json") {
    sql null-or {|x| $x | from json }
  } else { null }
}

# ---- orchestration ------------------------------------------------------------

# Load the schema cache for a connection, rebuilding when --refresh or stale.
def my-schema-load [conf: record, --refresh]: nothing -> record {
  let db = ($conf | get -o database | default "_")
  let file = (cache path "mysql" $"($conf.name)__($db)")
  if $refresh or (cache stale $file 1day) {
    let secs = [
        {k: "tables"      q: (myql tables-sql)}
        {k: "columns"     q: (myql columns-sql)}
        {k: "constraints" q: (myql constraints-sql)}
      ]
      | par-each {|s| {key: $s.k, rows: (my-rows $conf $s.q)} }
      | reduce --fold {} {|it, acc| $acc | upsert $it.key $it.rows }
    let body = (sql schema-body $secs.tables $secs.columns $secs.constraints {|c| myql display-type $c } (myql nulls))
    let data = ({meta: {connection: $conf.name, database: $db, driver: "mysql", refreshed_at: (date now)}} | merge $body)
    $data | cache write $file
    return $data
  }
  cache read $file
}

# The standard override record: named flags win over the resolved connection,
# and --set wins over the named flags (for arbitrary/driver-specific fields).
def my-conf [
  connection: any, host: any, port: any,
  user: any, password: any, database: any, set: record
]: nothing -> record {
  conn with mysql $connection ({
    host: $host, port: $port,
    user: $user, password: $password, database: $database
  } | merge $set)
}

# ---- completers (cache-backed; build the schema on a cache miss) --------------
# These call my-schema-load, so a first completion against a not-yet-cached (or
# day-stale) connection introspects the live DB once, then serves from cache.

def mysql-catalog [context: string]: nothing -> record {
  complete catalog-ctx $context mysql --get {|c| my-schema-load $c }
}

def "mysql-table" [context: string]: nothing -> list<string> {
  sql complete-tables (mysql-catalog $context)
}

# Comma-list variant for the `schema --include/--exclude` filters: re-prepend the
# already-typed tables so accepting a candidate extends the list.
def "mysql-tables-csv" [context: string]: nothing -> list<string> {
  let prefix = (complete token $context | str replace --regex '[^,]*$' '')
  sql complete-tables (mysql-catalog $context) | each {|t| $"($prefix)($t)" }
}

def "mysql-column" [context: string]: nothing -> list<string> {
  # `select` names its table with --from; `update`/`delete` take it as the leading
  # positional — fall back to that so column completion works for the write verbs too.
  let tbl = (complete flag $context [--from -F] | default (sql lead-arg $context [update delete]))
  sql complete-columns (mysql-catalog $context) $tbl
}

# Comma-list variant of `mysql-column` for the multi-value `--group-by` flag:
# re-prepend the already-typed columns so accepting a candidate extends the list
# (Nushell can't complete inside a `[...]` list literal).
def "mysql-columns-csv" [context: string]: nothing -> list<string> {
  let prefix = (complete token $context | str replace --regex '[^,]*$' '')
  mysql-column $context | each {|c| $"($prefix)($c)" }
}

# Completion-only bounded/quiet distinct-value probe: a read-only SELECT run with a
# short connect timeout and a `MAX_EXECUTION_TIME` optimizer hint (a bare comment on
# servers that don't support it, so it never errors), returning the `v` column's
# values (empty on any non-zero exit). Separate from `my-exec` so the verbs are
# untouched; the caller wraps it in `try` for parse errors.
def my-probe [conf: record, sql: string]: nothing -> list<string> {
  let db = ($conf | get -o database)
  let db_args = if ($db | is-not-empty) { ["-D" $db] } else { [] }
  let hinted = ($sql | str replace "SELECT DISTINCT" "SELECT /*+ MAX_EXECUTION_TIME(3000) */ DISTINCT")
  let r = (with-env { MYSQL_PWD: ($conf | get -o password | default "") } {
    $hinted | ^mysql --connect-timeout=3 -u ($conf | get -o user) -h ($conf | get -o host) -P ($conf | get -o port | default 3306) ...$db_args | complete
  })
  if ($r.exit_code != 0) { return [] }
  $r.stdout | from tsv --no-infer | get -o v | default []
}

# Completer for the rest slot that holds BOTH projections and `col<op>value`
# predicate tokens (`select`'s ...columns, `delete`'s ...predicates). A BARE token
# completes column names (like `mysql-column`). An `=`/`!=` token runs a LIVE,
# bounded `SELECT DISTINCT <col>` — scoped to the sibling predicates and `--from`
# table already on the line — and offers `col<op>value` for each distinct value
# (best-effort: unreachable/slow/errored → no candidates). Comparison/LIKE/`in:`
# tokens complete nothing; a distinct value with spaces/quotes may need manual
# quoting when accepted.
def "mysql-arg" [context: string]: nothing -> list<string> {
  let p = (sql predicate-token (complete token $context))
  if ($p == null) { return (mysql-column $context) }
  if ($p.op not-in ["=" "!="]) or ($p.value | str starts-with "in:") { return [] }
  let table = (complete flag $context [--from -F] | default (sql lead-arg $context [update delete]))
  let conf = (complete conn-ctx $context "mysql")
  if ($table | is-empty) or ($conf | is-empty) { return [] }
  let siblings = (sql split-args (complete positionals $context) | get predicates | where col != $p.col)
  # The probe SELECT frame (incl. LIMIT) is the driver's — mole-sql only composes the WHERE.
  let where = (sql build-where $siblings --dialect (myql dialect))
  let q = (sql assemble [
    $"SELECT DISTINCT ($p.col) AS v FROM ($table)"
    (if ($where | is-not-empty) { $"WHERE ($where)" })
    "LIMIT 50"
  ])
  (try { my-probe $conf $q } catch { [] }) | each {|v| $p.col + $p.op + $v }
}

def "mysql-lock" [context: string]: nothing -> list<string> { myql lock-modes }

# ---- user verbs ---------------------------------------------------------------

# Run an arbitrary SQL statement against a MySQL connection.
#
# The statement text is the positional <sql>, a saved `--file` (resolved under
# the query dir with a `.sql` suffix), or `$EDITOR` when neither is given. Cells
# come back LOSSLESS — every value is the string `mysql` printed in its
# tab-separated batch output, uncoerced (use `select` when you want DB-typed
# rows). A statement matching the dialect danger regex (writes, DDL, grants, …)
# prompts for confirmation first, which `--yes` skips. The connection is the
# current mysql one unless `--connection` names another; per-field flags and
# `--set` override individual fields.
#
# Named `raw-query`, not `run`, because `run` is a Nushell parser keyword. Reference
# invocations (leaf verb — call it as your loader exposes it, e.g. `mole-mysql raw-query`):
#
#   mole-mysql raw-query "SELECT now()"                                    # the current connection
#   mole-mysql raw-query "SELECT id, email FROM users ORDER BY id" -c mysql-local-dev
#   mole-mysql raw-query --file reports/active-users -c mysql-local-dev    # <querydir>/reports/active-users.sql
#   mole query show reports/active-users.sql | mole-mysql raw-query -c mysql-local-dev  # query text piped via stdin
#   mole-mysql raw-query "CREATE TEMPORARY TABLE t (id int)" -c mysql-local-dev --yes   # skip the danger prompt
@category mole-mysql
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
  let conf = (my-conf $connection $host $port $user $password $database $set)
  let text = ($in | query resolve $sql --file $file --suffix ".sql")
  if (query is-dangerous $text (myql dangerous)) and (not (query confirm "This query may modify data. Run it?" --yes=$yes)) {
    return
  }
  my-rows $conf $text
}

# Compose and run a single-table MySQL SELECT, returning DB-typed rows.
#
# Every clause body — the projected columns, `--where`, `--having`, `--group-by`
# keys, `--sort-by` terms — is passed to mysql VERBATIM, so expressions like
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
# `--where`. Flags render the mysql-specific frame around the clause bodies:
# `GROUP BY ... WITH ROLLUP` (`--rollup`), and the locks
# `FOR UPDATE|SHARE [OF ...] [SKIP LOCKED|NOWAIT]` plus the legacy
# `LOCK IN SHARE MODE` (`--lock share-mode`). MySQL has no `NULLS FIRST|LAST` and
# rejects a bare `OFFSET`, so `--offset` requires `--limit`.
#
# Only the `--from` table's cached columns are DB-typed (tinyint(1)→bool, int,
# decimal, date/datetime, json → real nu values); computed and aliased
# columns stay strings, but SQL NULLs are normalized to `null` across every
# column (so a NULL reads the same here as on Postgres, not `"NULL"` vs `""`).
# Pass `--raw` for the untouched, fully lossless rows (no typing, no null-
# normalization). `--dry-run` returns a `{connection, query}` record — the resolved
# connection (secrets dropped) and the assembled SQL — without running it. A `--lock` clause locks the matched rows, so it
# prompts unless you pass `--yes`. Connection is overridable via `--connection` +
# per-field flags / `--set`, as in `raw-query`.
@category mole-mysql
@example "every column of a table" {
  mole-mysql select --from users --dry-run | get query
} --result "SELECT * FROM users"
@example "project, filter, order and limit" {
  mole-mysql select id email --from users --where "age > 30" --sort-by "age desc" --limit 5 --dry-run | get query
} --result "SELECT id, email FROM users WHERE age > 30 ORDER BY age DESC LIMIT 5"
@example "DISTINCT" {
  mole-mysql select status --distinct --from orders --dry-run | get query
} --result "SELECT DISTINCT status FROM orders"
@example "aggregate with GROUP BY and HAVING" {
  mole-mysql select user_id "count(*) AS n" --from orders --group-by user_id --having "count(*) > 1" --sort-by "n desc" --dry-run | get query
} --result "SELECT user_id, count(*) AS n FROM orders GROUP BY user_id HAVING count(*) > 1 ORDER BY n DESC"
@example "GROUP BY ... WITH ROLLUP (mysql-specific) — subtotal + grand-total rows" {
  mole-mysql select dept "count(*) AS n" --from employees --group-by dept --rollup --dry-run | get query
} --result "SELECT dept, count(*) AS n FROM employees GROUP BY dept WITH ROLLUP"
@example "multi-key ORDER BY" {
  mole-mysql select name salary --from employees --sort-by "salary desc, name asc" --dry-run | get query
} --result "SELECT name, salary FROM employees ORDER BY salary DESC, name ASC"
@example "pagination with LIMIT + OFFSET (OFFSET requires LIMIT)" {
  mole-mysql select --from users --sort-by id --limit 2 --offset 2 --dry-run | get query
} --result "SELECT * FROM users ORDER BY id LIMIT 2 OFFSET 2"
@example "shared read lock: LOCK IN SHARE MODE (mysql-specific spelling)" {
  mole-mysql select --from orders --where "status = 'pending'" --lock share-mode --dry-run | get query
} --result "SELECT * FROM orders WHERE status = 'pending' LOCK IN SHARE MODE"
@example "row lock: FOR UPDATE SKIP LOCKED (needs --yes to run for real)" {
  mole-mysql select --from orders --lock update --skip-locked --dry-run | get query
} --result "SELECT * FROM orders FOR UPDATE SKIP LOCKED"
@example "extract JSON verbatim" {
  mole-mysql select sku "json_extract(attrs, '$.color') AS color" --from products --dry-run | get query
} --result "SELECT sku, json_extract(attrs, '$.color') AS color FROM products"
@example "predicate tokens compose the WHERE clause (columns complete)" {
  mole-mysql select id email --from users status=active age>=30 --dry-run | get query
} --result "SELECT id, email FROM users WHERE status = 'active' AND age >= 30"
@example "IN, LIKE and NULL predicate forms, AND-combined with a raw --where" {
  mole-mysql select --from users role=in:admin,ops name~%acme% deleted=null --where "score > 0" --dry-run | get query
} --result "SELECT * FROM users WHERE role IN ('admin', 'ops') AND name LIKE '%acme%' AND deleted IS NULL AND (score > 0)"
@example "run for real — tinyint(1)→bool, decimal→float, json→record/list" {
  mole-mysql select sku in_stock price tags attrs --from products --sort-by id -c mysql-local-dev
}
export def "select" [
  ...columns: string@"mysql-arg"                   # projected columns, or `col<op>value` predicate tokens (default: *)
  --from(-F): string@"mysql-table"                 # source table, single table only (an alias is allowed: "users u")
  --where(-w): string                              # raw WHERE predicate, AND-combined with any col<op>value tokens
  --group-by(-g): string@"mysql-columns-csv"       # GROUP BY keys, comma-separated
  --rollup                                         # append WITH ROLLUP to GROUP BY (mysql-specific)
  --having: string                                 # HAVING predicate (without the keyword)
  --sort-by(-s): string                            # ORDER BY terms, comma-separated: "col [asc|desc]"
  --limit(-l): int                                 # LIMIT N
  --offset(-o): int                                # OFFSET N (requires --limit)
  --distinct                                       # SELECT DISTINCT
  --lock: string@"mysql-lock"                      # row lock: update | share | share-mode (LOCK IN SHARE MODE)
  --lock-of: string@"mysql-tables-csv"             # FOR ... OF <tables>, comma-separated (update/share only)
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
    error make {msg: "select: --offset requires --limit (MySQL rejects a bare OFFSET)"}
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
  let conf = (my-conf $connection $host $port $user $password $database $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  # A composed SELECT can only ever read — the sole side effect it can carry is a
  # row lock, so gate the prompt on that, not on scanning the user's clause bodies.
  if ($lock | is-not-empty) and (not (query confirm "This locks the matched rows. Run it?" --yes=$yes)) {
    return
  }
  let rows = (my-rows $conf $text)
  if $raw { return $rows }
  $rows
  | sql normalize-nulls (myql nulls)
  | sql apply-types (sql columns-for (my-schema-load $conf) (sql base-table $from)) {|c| my-type $c }
}

# Compose and run a single-table MySQL UPDATE.
#
# Reads like the statement: `update <table> <assignment>...`. The table is the
# leading positional (completing table names); the SET assignments follow as
# positionals — each a verbatim `"col = expr"`, so expressions (`hits = hits + 1`,
# `updated_at = now()`) all work; you quote identifiers and string literals
# yourself, and their column names complete against the table. `--where` is the
# same verbatim predicate as `select`. MySQL scopes a single-table UPDATE with an
# optional `ORDER BY ... LIMIT` (`--sort-by` / `--limit`) — the bounded-rewrite
# idiom; there is NO RETURNING and NO join support (reach for `raw-query` for
# multi-table updates).
#
# UPDATE always writes, so it prompts before running (skip with `--yes`) and
# REFUSES to touch every row unless you pass `--all` (a missing `--where` would
# otherwise rewrite the whole table). `--dry-run` returns a `{connection, query}`
# record without running. Connection overridable via `--connection` + per-field
# flags / `--set`, as in `raw-query`.
@category mole-mysql
@example "set a column on the matched rows" {
  mole-mysql update users "status = 'inactive'" --where "id = 5" --dry-run | get query
} --result "UPDATE users SET status = 'inactive' WHERE id = 5"
@example "several assignments at once" {
  mole-mysql update users "status = 'active'" "verified = 1" --where "email = 'a@b.c'" --dry-run | get query
} --result "UPDATE users SET status = 'active', verified = 1 WHERE email = 'a@b.c'"
@example "bounded rewrite: ORDER BY ... LIMIT (mysql-specific)" {
  mole-mysql update jobs "priority = priority + 1" --where "queued = 1" --sort-by "created_at asc" --limit 100 --dry-run | get query
} --result "UPDATE jobs SET priority = priority + 1 WHERE queued = 1 ORDER BY created_at ASC LIMIT 100"
@example "guard: an unfiltered UPDATE needs --all" {
  mole-mysql update users "archived = 1" --all --dry-run | get query
} --result "UPDATE users SET archived = 1"
export def "update" [
  table: string@"mysql-table"                      # target table (UPDATE <table>); single table, an alias is allowed: "users u"
  ...assignments: string@"mysql-column"            # SET assignments, verbatim "col = expr" (at least one required)
  --where(-w): string                              # WHERE predicate (without the keyword)
  --sort-by(-s): string                            # ORDER BY terms, comma-separated: "col [asc|desc]" (with --limit)
  --limit(-l): int                                 # LIMIT N — cap the rows changed (mysql-specific)
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
  let conf = (my-conf $connection $host $port $user $password $database $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (not (query confirm "This UPDATE will modify rows. Run it?" --yes=$yes)) { return }
  my-rows $conf $text
}

# Compose and run a single-table MySQL DELETE.
#
# Reads like the statement: `delete <table> <predicate>...`. The table is the
# leading positional (completing table names); the `col<op>value` predicate tokens
# (`user_id=7`, `status=inactive`, `role=in:a,b`) are AND-joined into the WHERE
# clause, their column names completing — the same grammar as `select`. `--where`
# is the raw escape (for an expression RHS like `now()`, `OR`, a sub-select),
# AND-combined with the tokens. Like UPDATE, MySQL scopes a single-table DELETE with
# an optional `ORDER BY ... LIMIT` (`--sort-by` / `--limit`) — delete the "oldest N"
# and so on. There is NO RETURNING and NO join support (reach for `raw-query` for
# `DELETE ... USING`/multi-table).
#
# DELETE always writes, so it prompts before running (skip with `--yes`) and
# REFUSES to delete every row unless you pass `--all`. `--dry-run` returns a
# `{connection, query}` record without running. Connection overridable as in
# `raw-query`.
@category mole-mysql
@example "predicate tokens build the filter (columns complete)" {
  mole-mysql delete sessions user_id=7 --dry-run | get query
} --result "DELETE FROM sessions WHERE user_id = 7"
@example "an expression filter uses the raw --where" {
  mole-mysql delete sessions --where "expires_at < now()" --dry-run | get query
} --result "DELETE FROM sessions WHERE expires_at < now()"
@example "delete the oldest N (ORDER BY ... LIMIT)" {
  mole-mysql delete logs --where "level = 'debug'" --sort-by "ts asc" --limit 1000 --dry-run | get query
} --result "DELETE FROM logs WHERE level = 'debug' ORDER BY ts ASC LIMIT 1000"
@example "guard: an unfiltered DELETE needs --all" {
  mole-mysql delete staging_rows --all --dry-run | get query
} --result "DELETE FROM staging_rows"
export def "delete" [
  table: string@"mysql-table"                      # target table (DELETE FROM <table>); single table, an alias is allowed: "users u"
  ...predicates: string@"mysql-arg"                # `col<op>value` filter tokens (AND-joined): user_id=7  status=inactive  role=in:a,b
  --where(-w): string                              # raw WHERE predicate, AND-combined with any predicate tokens
  --sort-by(-s): string                            # ORDER BY terms, comma-separated: "col [asc|desc]" (with --limit)
  --limit(-l): int                                 # LIMIT N — cap the rows removed (mysql-specific)
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
  let conf = (my-conf $connection $host $port $user $password $database $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (not (query confirm "This DELETE will remove rows. Run it?" --yes=$yes)) { return }
  my-rows $conf $text
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
@category mole-mysql
@example "summary — one row per table" {
  mole-mysql schema -c mysql-local-dev
}
@example "detail for one table (its columns + constraints)" {
  mole-mysql schema --table users -c mysql-local-dev
}
@example "search names and comments for 'balance'" {
  mole-mysql schema --find balance -c mysql-local-dev
}
@example "rebuild the cache from the live database first" {
  mole-mysql schema --refresh -c mysql-local-dev
}
@example "the raw cache record, including meta" {
  mole-mysql schema --full -c mysql-local-dev
}
@example "render only the core tables as a Mermaid ER diagram" {
  mole-mysql schema --full --include "users,orders,order_items" -c mysql-local-dev | mole-mermaid er-schema
}
@example "dump everything except housekeeping tables" {
  mole-mysql schema --full --exclude "*_audit,django_*" -c mysql-local-dev
}
export def "schema" [
  --connection(-c): string@complete-connection   # named connection (default: current)
  --table(-t): string@"mysql-table"                # detail view for one table
  --find: string                                   # find tables/columns by name or comment (case-insensitive)
  --refresh(-r)                                    # rebuild the cache before reading
  --full                                           # return the full cache record
  --include: string@"mysql-tables-csv"             # keep ONLY these tables — comma-sep names/globs (mutually exclusive with --exclude)
  --exclude: string@"mysql-tables-csv"             # drop these tables — comma-sep names/globs (mutually exclusive with --include)
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
  let conf = (my-conf $connection $host $port $user $password $database $set)
  let data = (sql schema-filter (my-schema-load $conf --refresh=$refresh) --include (sql csv-split $include) --exclude (sql csv-split $exclude))
  if $full { return $data }
  if ($find | is-not-empty) {
    sql schema-find $data $find
  } else if ($table | is-not-empty) {
    sql schema-detail $data $table
  } else {
    sql schema-tables $data
  }
}

# Make a mysql connection the current one for this driver.
#
# Records the choice in `$env.MOLE_CURRENT.mysql`, so later `run` / `select` /
# `schema` calls can omit `--connection`. Validates that `name` exists and is
# actually a mysql connection (errors otherwise). Being `--env`, the change
# persists in the caller's environment.
@category mole-mysql
@example "make the local dev database current" {
  mole-mysql set-connection mysql-local-dev
}
export def --env "set-connection" [
  name: string@complete-connection   # a mysql connection name (from the connections file)
]: nothing -> nothing {
  conn set-current mysql $name | ignore
}
