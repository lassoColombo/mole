# mole-mysql — MySQL driver plugin.
#
# A PLUGIN (data source): supports the mysql technology, registers itself as a
# driver, and exposes the user verbs `query` / `select` / `schema`. It DEPENDS on:
#   - mole core plumbing        (`use mole/lib/*.nu`)
#   - the generic mole-sql pure LIBRARY (`use mole-sql/sql.nu`)
#
# LAYERING: everything driver-specific (how to invoke mysql, the introspection
# SQL, the type map, the danger regex) and all orchestration (resolve → exec →
# check → parse → cache → type) lives HERE; the library only receives data and
# closures. This is the sibling of mole-psql, differing only in these private
# dialect pieces (stdin exec + MYSQL_PWD, tsv parse, information_schema SQL,
# mysql type map with tinyint(1)→bool, display-type from column_type).

use mole/lib/conn.nu

# Driver-scoped connection completer: only THIS driver (mysql), never other drivers.
def "complete-connection" []: nothing -> list<string> { conn names "mysql" }
use mole/lib/cache.nu
use mole/lib/query.nu
use mole/lib/complete.nu
use mole-sql/sql.nu

const HERE = (path self | path dirname)

export-env {
  let m = (open ([$HERE mole.nuon] | path join))
  $env.MOLE_REGISTRY = (($env.MOLE_REGISTRY? | default {}) | upsert $m.driver $m)
  $env.MOLE_CURRENT = ($env.MOLE_CURRENT? | default {})
}

# ---- dialect specifics (mysql) ------------------------------------------------

# How `mysql`'s batch (tab-separated) output renders a SQL NULL: the literal text
# `NULL` (an empty field is a genuine empty string). Injected into the mole-sql
# normalizers so the pure library carries no knowledge of NULL spelling.
const MY_NULLS = ["NULL"]

# Statements that warrant a confirmation prompt before running.
def my-dangerous []: nothing -> string {
  '(?i)\b(delete|drop|truncate|update|insert|replace|create|alter|rename|grant|revoke|lock|unlock|analyze|optimize|repair|flush|kill|shutdown|load\s+data|outfile|dumpfile|call|execute|prepare|deallocate|set\s+global)\b'
}

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

# data_type → cell-converter closure (or null to leave the column as-is).
# By convention tinyint(1) is a boolean.
def my-type [col: record]: nothing -> any {
  if (($col | get -o data_type) == "tinyint") and (($col | get -o display_type) == "tinyint(1)") {
    return (sql null-or {|x| ($x | into int) != 0 })
  }
  match ($col | get -o data_type) {
    "tinyint" | "smallint" | "mediumint" | "int" | "bigint" => (sql null-or {|x| $x | into int })
    "float" | "double" | "decimal" => (sql null-or {|x| $x | into float })
    "date" | "datetime" | "timestamp" => (sql null-or {|x| $x | into datetime })
    "json" => (sql null-or {|x| $x | from json })
    _ => null
  }
}

# mysql already gives us "varchar(255)" via column_type (stashed in udt_name).
def my-display-type [c: record]: nothing -> string {
  let ct = ($c | get -o udt_name)
  if ($ct | is-not-empty) { ($ct | into string) } else { ($c.data_type | into string) }
}

def my-tables-sql []: nothing -> string {
  r#'
    SELECT
      table_schema   AS `schema`,
      table_name     AS `name`,
      table_type     AS `type`,
      table_comment  AS `comment`,
      COALESCE(table_rows, 0) AS `row_estimate`
    FROM information_schema.tables
    WHERE table_schema = COALESCE(DATABASE(), table_schema)
      AND table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
    ORDER BY table_schema, table_name
  '#
}

def my-columns-sql []: nothing -> string {
  r#'
    SELECT
      table_schema  AS `schema`,
      table_name    AS `table`,
      column_name   AS `name`,
      ordinal_position AS `position`,
      data_type     AS `data_type`,
      column_type   AS `udt_name`,
      is_nullable   AS `is_nullable`,
      column_default AS `default`,
      character_maximum_length AS `char_max_length`,
      numeric_precision AS `numeric_precision`,
      numeric_scale AS `numeric_scale`,
      column_comment AS `comment`
    FROM information_schema.columns
    WHERE table_schema = COALESCE(DATABASE(), table_schema)
      AND table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
    ORDER BY table_schema, table_name, ordinal_position
  '#
}

def my-constraints-sql []: nothing -> string {
  r#'
    SELECT
      tc.table_schema  AS `schema`,
      tc.table_name    AS `table`,
      tc.constraint_name AS `name`,
      tc.constraint_type AS `type`,
      GROUP_CONCAT(kcu.column_name ORDER BY kcu.ordinal_position) AS `columns`,
      MAX(kcu.referenced_table_schema) AS `ref_schema`,
      MAX(kcu.referenced_table_name)   AS `ref_table`,
      CASE WHEN tc.constraint_type = 'FOREIGN KEY'
        THEN GROUP_CONCAT(kcu.referenced_column_name ORDER BY kcu.ordinal_position)
      END AS `ref_columns`
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON kcu.table_schema    = tc.table_schema
     AND kcu.table_name      = tc.table_name
     AND kcu.constraint_name = tc.constraint_name
    WHERE tc.constraint_type IN ('PRIMARY KEY','FOREIGN KEY','UNIQUE')
      AND tc.table_schema = COALESCE(DATABASE(), tc.table_schema)
      AND tc.table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
    GROUP BY tc.table_schema, tc.table_name, tc.constraint_name, tc.constraint_type
    ORDER BY tc.table_schema, tc.table_name, FIELD(tc.constraint_type,'PRIMARY KEY','UNIQUE','FOREIGN KEY'), tc.constraint_name
  '#
}

# ---- orchestration ------------------------------------------------------------

# Load the schema cache for a connection, rebuilding when --refresh or stale.
def my-schema-load [conf: record, --refresh]: nothing -> record {
  let db = ($conf | get -o database | default "_")
  let file = (cache path "mysql" $"($conf.name)__($db)")
  if $refresh or (cache stale $file 1day) {
    let secs = [
        {k: "tables"      q: (my-tables-sql)}
        {k: "columns"     q: (my-columns-sql)}
        {k: "constraints" q: (my-constraints-sql)}
      ]
      | par-each {|s| {key: $s.k, rows: (my-rows $conf $s.q)} }
      | reduce --fold {} {|it, acc| $acc | upsert $it.key $it.rows }
    let body = (sql schema-body $secs.tables $secs.columns $secs.constraints {|c| my-display-type $c } $MY_NULLS)
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

def "mysql-table" [context: string]: nothing -> list<string> {
  try {
    let conf = (conn with mysql (sql parse-flag $context ["--connection" "-c"]) {})
    sql complete-tables (my-schema-load $conf | default {})
  } catch { [] }
}

def "mysql-column" [context: string]: nothing -> list<string> {
  try {
    let conf = (conn with mysql (sql parse-flag $context ["--connection" "-c"]) {})
    let tbl = (sql parse-flag $context ["--from" "-F"])
    sql complete-columns (my-schema-load $conf | default {}) $tbl
  } catch { [] }
}

def "mysql-lock" [context: string]: nothing -> list<string> { [update share share-mode] }

# ---- SELECT clause renderers (mysql-specific) ---------------------------------

# SELECT head: `SELECT [DISTINCT] <cols>` (cols verbatim). MySQL has no DISTINCT ON.
def my-projection [columns: list<string>, distinct: bool]: nothing -> string {
  let cols = if ($columns | is-empty) { "*" } else { $columns | str join ", " }
  $"SELECT (if $distinct { 'DISTINCT ' } else { '' })($cols)"
}

# One ORDER BY term: "<expr> [ASC|DESC]" (expr verbatim). MySQL has no NULLS ordering.
def my-order-term [term: string]: nothing -> string {
  let toks = ($term | str trim | split row --regex '\s+')
  if ($toks | is-empty) or (($toks | first) == "") { return "" }
  let m = ($toks | length)
  if $m >= 1 and (($toks | last | str lowercase) in [asc desc]) {
    $"($toks | first ($m - 1) | str join ' ') (($toks | last) | str uppercase)"
  } else {
    $toks | str join ' '
  }
}

# ORDER BY from a comma-separated --sort-by string, or null when empty.
def my-order [sort_by: any]: nothing -> any {
  if ($sort_by | is-empty) { return null }
  let terms = ($sort_by | split row "," | each {|t| my-order-term $t } | where {|t| $t | is-not-empty })
  sql join-list $terms --prefix "ORDER BY "
}

# Locking tail. "share-mode" → legacy `LOCK IN SHARE MODE` (no OF/wait policy);
# "update"/"share" → `FOR UPDATE`/`FOR SHARE` [OF ...] [SKIP LOCKED|NOWAIT]. null if unset.
def my-lock [lock: any, lock_of: list<string>, skip_locked: bool, nowait: bool]: nothing -> any {
  if ($lock | is-empty) { return null }
  if (($lock | str lowercase) == "share-mode") { return "LOCK IN SHARE MODE" }
  let mode = if (($lock | str lowercase) == "share") { "FOR SHARE" } else { "FOR UPDATE" }
  let wait = if $skip_locked { "SKIP LOCKED" } else if $nowait { "NOWAIT" } else { null }
  sql assemble [$mode (sql join-list $lock_of --prefix "OF ") $wait]
}

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
# Named `query`, not `run`, because `run` is a Nushell parser keyword. Reference
# invocations (leaf verb — call it as your loader exposes it, e.g. `mole-mysql query`):
#
#   mole-mysql query "SELECT now()"                                    # the current connection
#   mole-mysql query "SELECT id, email FROM users ORDER BY id" -c mysql-local-dev
#   mole-mysql query --file reports/active-users -c mysql-local-dev    # <querydir>/reports/active-users.sql
#   mole query show reports/active-users.sql | mole-mysql query -c mysql-local-dev  # query text piped via stdin
#   mole-mysql query "CREATE TEMPORARY TABLE t (id int)" -c mysql-local-dev --yes   # skip the danger prompt
@category mole-mysql
export def "query" [
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
  if (sql is-dangerous $text (my-dangerous)) and (not (query confirm "This query may modify data. Run it?" --yes=$yes)) {
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
# table. Flags render the mysql-specific frame around the clause bodies:
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
# per-field flags / `--set`, as in `query`.
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
  mole-mysql select user_id "count(*) AS n" --from orders --group-by [user_id] --having "count(*) > 1" --sort-by "n desc" --dry-run | get query
} --result "SELECT user_id, count(*) AS n FROM orders GROUP BY user_id HAVING count(*) > 1 ORDER BY n DESC"
@example "GROUP BY ... WITH ROLLUP (mysql-specific) — subtotal + grand-total rows" {
  mole-mysql select dept "count(*) AS n" --from employees --group-by [dept] --rollup --dry-run | get query
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
@example "run for real — tinyint(1)→bool, decimal→float, json→record/list" {
  mole-mysql select sku in_stock price tags attrs --from products --sort-by id -c mysql-local-dev
}
export def "select" [
  ...columns: string@"mysql-column"                # projected columns/expressions (default: *)
  --from(-F): string@"mysql-table"                 # source table, single table only (an alias is allowed: "users u")
  --where(-w): string                              # WHERE predicate (without the keyword)
  --group-by(-g): list<string>@"mysql-column"      # GROUP BY keys
  --rollup                                         # append WITH ROLLUP to GROUP BY (mysql-specific)
  --having: string                                 # HAVING predicate (without the keyword)
  --sort-by(-s): string                            # ORDER BY terms, comma-separated: "col [asc|desc]"
  --limit(-l): int                                 # LIMIT N
  --offset(-o): int                                # OFFSET N (requires --limit)
  --distinct                                       # SELECT DISTINCT
  --lock: string@"mysql-lock"                      # row lock: update | share | share-mode (LOCK IN SHARE MODE)
  --lock-of: list<string>@"mysql-table"            # FOR ... OF <tables> (update/share only)
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
  let group_frag = (sql join-list ($group_by | default []) --prefix "GROUP BY ")
  let group_frag = if ($group_frag != null) and $rollup { $group_frag + " WITH ROLLUP" } else { $group_frag }
  let text = (sql assemble [
    (my-projection $columns $distinct)
    $"FROM ($from)"
    (if ($where | is-not-empty) { $"WHERE ($where)" })
    $group_frag
    (if ($having | is-not-empty) { $"HAVING ($having)" })
    (my-order $sort_by)
    (if $limit != null { $"LIMIT ($limit)" })
    (if $offset != null { $"OFFSET ($offset)" })
    (my-lock $lock ($lock_of | default []) $skip_locked $nowait)
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
  | sql normalize-nulls $MY_NULLS
  | sql apply-types (sql columns-for (my-schema-load $conf) (sql base-table $from)) {|c| my-type $c }
}

# Inspect a connection's cached schema (introspection is cached for a day).
#
# The default view is one summary row per table: schema, name, type, column
# count, primary key, row estimate, comment. `--table` switches to the full
# detail for one table (its columns and constraints); `--find` searches table and
# column names and comments case-insensitively; `--full` returns the raw cache
# record, including its `meta`. `--refresh` rebuilds the cache from the live
# database before reading. Connection is overridable exactly as in `run`.
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
export def "schema" [
  --connection(-c): string@complete-connection   # named connection (default: current)
  --table(-t): string@"mysql-table"                # detail view for one table
  --find: string                                   # find tables/columns by name or comment (case-insensitive)
  --refresh(-r)                                    # rebuild the cache before reading
  --full                                           # return the full cache record
  --host(-h): string                               # override host
  --port(-p): int                                  # override port
  --user(-u): string                               # override user
  --password(-P): string                           # override password
  --database(-d): string                           # override database
  --set: record = {}                               # override any other connection field(s)
] {
  let conf = (my-conf $connection $host $port $user $password $database $set)
  let data = (my-schema-load $conf --refresh=$refresh)
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
  conn resolve $name --driver mysql | ignore
  $env.MOLE_CURRENT = (($env.MOLE_CURRENT? | default {}) | upsert mysql $name)
}
