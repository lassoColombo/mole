# mole-psql — PostgreSQL driver plugin.
#
# A PLUGIN (data source): supports the postgres technology, registers itself as a
# driver, and exposes the user verbs `raw-query` / `select` / `schema`. It DEPENDS on:
#   - mole core plumbing        (`use mole/lib/*.nu`)
#   - the generic mole-sql pure LIBRARY (`use mole-sql/sql.nu`)
# The mole-sql library must be reachable via `NU_LIB_DIRS`.
#
# LAYERING: everything driver-specific (how to invoke psql, the introspection
# SQL, the type map, the danger regex) and all orchestration (resolve → exec →
# check → parse → cache → type) lives HERE. The library only ever receives data
# and closures. mole-mysql is a near-identical sibling that differs only in these
# private dialect pieces — this file is its template.

use mole/lib/conn.nu

# Driver-scoped connection completer: only THIS driver (psql), never other drivers.
def "complete-connection" []: nothing -> list<string> { conn names "psql" }
use mole/lib/cache.nu
use mole/lib/query.nu
use mole/lib/complete.nu
use mole-sql/sql.nu

export-env {
  conn register "psql"
}

# ---- dialect specifics (postgres) --------------------------------------------

# How `psql --csv` renders a SQL NULL: an empty field. Injected into the mole-sql
# normalizers (schema-body, normalize-nulls) so the pure library carries no
# knowledge of how this dialect spells NULL.
const PG_NULLS = [""]

# Statements that warrant a confirmation prompt before running.
def pg-dangerous []: nothing -> string {
  '(?i)\b(delete|drop|truncate|update|insert|copy|create|alter|rename|grant|revoke|lock|analyze|vacuum|reindex|cluster|commit|rollback|savepoint|release|attach|detach|prepare|deallocate|execute|notify|listen)\b'
}

# Run one SQL statement, returning a `complete` record. Password via PGPASSWORD;
# output as CSV so it parses losslessly.
def pg-exec [conf: record, sql: string]: nothing -> record {
  let db = ($conf | get -o database)
  let db_args = if ($db | is-not-empty) { ["-d" $db] } else { [] }
  with-env { PGPASSWORD: ($conf | get -o password | default "") } {
    ^psql -h $conf.host -p ($conf | get -o port | default 5432) -U $conf.user ...$db_args --csv -q -c $sql | complete
  }
}

# Exec + check + lossless parse (every cell stays a string).
def pg-rows [conf: record, sql: string]: nothing -> any {
  pg-exec $conf $sql | query check | from csv --no-infer
}

# data_type → cell-converter closure (or null to leave the column as-is).
def pg-type [col: record]: nothing -> any {
  match ($col | get -o data_type) {
    "boolean" => (sql null-or {|x| ($x | str lowercase) in ["t" "true" "yes" "1"] })
    "smallint" | "integer" | "bigint" => (sql null-or {|x| $x | into int })
    "real" | "double precision" | "numeric" => (sql null-or {|x| $x | into float })
    "date" | "timestamp without time zone" | "timestamp with time zone" => (sql null-or {|x| $x | into datetime })
    "json" | "jsonb" => (sql null-or {|x| $x | from json })
    _ => null
  }
}

# Friendly column type synthesized from the parts (e.g. varchar(255), numeric(10,2)).
def pg-display-type [c: record]: nothing -> string {
  let base = ($c.data_type | into string)
  let l = ($c | get -o char_max_length)
  if $l != null { return $"($base)\(($l))" }
  let p = ($c | get -o numeric_precision)
  if $p != null and ($base in ["numeric" "decimal"]) {
    let s = ($c | get -o numeric_scale | default 0)
    return $"($base)\(($p),($s))"
  }
  $base
}

def pg-tables-sql []: nothing -> string {
  r#'
    SELECT
      n.nspname AS "schema",
      c.relname AS "name",
      CASE c.relkind
        WHEN 'r' THEN 'BASE TABLE'
        WHEN 'v' THEN 'VIEW'
        WHEN 'm' THEN 'MATERIALIZED VIEW'
        WHEN 'f' THEN 'FOREIGN TABLE'
        WHEN 'p' THEN 'PARTITIONED TABLE'
      END AS "type",
      obj_description(c.oid) AS "comment",
      c.reltuples::bigint AS "row_estimate"
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r','v','m','f','p')
      AND n.nspname NOT IN ('pg_catalog','information_schema')
    ORDER BY n.nspname, c.relname
  '#
}

def pg-columns-sql []: nothing -> string {
  r#'
    SELECT
      c.table_schema AS "schema",
      c.table_name AS "table",
      c.column_name AS "name",
      c.ordinal_position AS "position",
      c.data_type AS "data_type",
      c.udt_name AS "udt_name",
      c.is_nullable AS "is_nullable",
      c.column_default AS "default",
      c.character_maximum_length AS "char_max_length",
      c.numeric_precision AS "numeric_precision",
      c.numeric_scale AS "numeric_scale",
      pgd.description AS "comment"
    FROM information_schema.columns c
    LEFT JOIN pg_catalog.pg_class pc
      ON pc.relname = c.table_name
     AND pc.relnamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = c.table_schema)
    LEFT JOIN pg_catalog.pg_description pgd
      ON pgd.objoid = pc.oid AND pgd.objsubid = c.ordinal_position
    WHERE c.table_schema NOT IN ('pg_catalog','information_schema')
    ORDER BY c.table_schema, c.table_name, c.ordinal_position
  '#
}

def pg-constraints-sql []: nothing -> string {
  r#'
    SELECT
      n.nspname AS "schema",
      c.relname AS "table",
      con.conname AS "name",
      CASE con.contype
        WHEN 'p' THEN 'PRIMARY KEY'
        WHEN 'f' THEN 'FOREIGN KEY'
        WHEN 'u' THEN 'UNIQUE'
      END AS "type",
      (SELECT string_agg(att.attname, ',' ORDER BY u.ord)
         FROM unnest(con.conkey) WITH ORDINALITY AS u(attnum, ord)
         JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = u.attnum) AS "columns",
      fn.nspname AS "ref_schema",
      fc.relname AS "ref_table",
      CASE WHEN con.contype = 'f' THEN
        (SELECT string_agg(fatt.attname, ',' ORDER BY u.ord)
           FROM unnest(con.confkey) WITH ORDINALITY AS u(attnum, ord)
           JOIN pg_attribute fatt ON fatt.attrelid = con.confrelid AND fatt.attnum = u.attnum)
      END AS "ref_columns"
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_class fc ON fc.oid = con.confrelid AND con.contype = 'f'
    LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
    WHERE con.contype IN ('p','f','u')
      AND n.nspname NOT IN ('pg_catalog','information_schema')
    ORDER BY n.nspname, c.relname, con.contype, con.conname
  '#
}

# ---- orchestration ------------------------------------------------------------

# Load the schema cache for a connection, rebuilding when --refresh or stale.
def pg-schema-load [conf: record, --refresh]: nothing -> record {
  let db = ($conf | get -o database | default "_")
  let file = (cache path "psql" $"($conf.name)__($db)")
  if $refresh or (cache stale $file 1day) {
    let secs = [
        {k: "tables"      q: (pg-tables-sql)}
        {k: "columns"     q: (pg-columns-sql)}
        {k: "constraints" q: (pg-constraints-sql)}
      ]
      | par-each {|s| {key: $s.k, rows: (pg-rows $conf $s.q)} }
      | reduce --fold {} {|it, acc| $acc | upsert $it.key $it.rows }
    let body = (sql schema-body $secs.tables $secs.columns $secs.constraints {|c| pg-display-type $c } $PG_NULLS)
    let data = ({meta: {connection: $conf.name, database: $db, driver: "psql", refreshed_at: (date now)}} | merge $body)
    $data | cache write $file
    return $data
  }
  cache read $file
}

# The standard override record: named flags win over the resolved connection,
# and --set wins over the named flags (for arbitrary/driver-specific fields).
def pg-conf [
  connection: any, host: any, port: any,
  user: any, password: any, database: any, set: record
]: nothing -> record {
  conn with psql $connection ({
    host: $host, port: $port,
    user: $user, password: $password, database: $database
  } | merge $set)
}

# ---- completers (cache-backed; build the schema on a cache miss) --------------
# These call pg-schema-load, so a first completion against a not-yet-cached (or
# day-stale) connection introspects the live DB once, then serves from cache.

def "psql-table" [context: string]: nothing -> list<string> {
  try {
    let conf = (conn with psql (sql parse-flag $context ["--connection" "-c"]) {})
    sql complete-tables (pg-schema-load $conf | default {})
  } catch { [] }
}

def "psql-column" [context: string]: nothing -> list<string> {
  try {
    let conf = (conn with psql (sql parse-flag $context ["--connection" "-c"]) {})
    let tbl = (sql parse-flag $context ["--from" "-F"])
    sql complete-columns (pg-schema-load $conf | default {}) $tbl
  } catch { [] }
}

def "psql-lock" [context: string]: nothing -> list<string> { ["update" "share" "no key update" "key share"] }

# ---- SELECT clause renderers (postgres-specific) ------------------------------

# SELECT head: `SELECT [DISTINCT | DISTINCT ON (...)] <cols>` (cols verbatim).
def pg-projection [columns: list<string>, distinct: bool, distinct_on: list<string>]: nothing -> string {
  let cols = if ($columns | is-empty) { "*" } else { $columns | str join ", " }
  let quant = if ($distinct_on | is-not-empty) {
    "DISTINCT ON (" + ($distinct_on | str join ", ") + ") "
  } else if $distinct {
    "DISTINCT "
  } else {
    ""
  }
  $"SELECT ($quant)($cols)"
}

# One ORDER BY term: "<expr> [ASC|DESC] [NULLS FIRST|LAST]" (expr verbatim).
def pg-order-term [term: string]: nothing -> string {
  let toks = ($term | str trim | split row --regex '\s+')
  if ($toks | is-empty) or (($toks | first) == "") { return "" }
  mut rest = $toks
  mut nulls = ""
  let n = ($rest | length)
  if $n >= 2 and (($rest | get ($n - 2) | str lowercase) == "nulls") and (($rest | last | str lowercase) in [first last]) {
    $nulls = $" NULLS (($rest | last) | str uppercase)"
    $rest = ($rest | first ($n - 2))
  }
  mut dir = ""
  let m = ($rest | length)
  if $m >= 1 and (($rest | last | str lowercase) in [asc desc]) {
    $dir = $" (($rest | last) | str uppercase)"
    $rest = ($rest | first ($m - 1))
  }
  $"($rest | str join ' ')($dir)($nulls)"
}

# ORDER BY from a comma-separated --sort-by string, or null when empty.
def pg-order [sort_by: any]: nothing -> any {
  if ($sort_by | is-empty) { return null }
  let terms = ($sort_by | split row "," | each {|t| pg-order-term $t } | where {|t| $t | is-not-empty })
  sql join-list $terms --prefix "ORDER BY "
}

# Locking tail: `FOR <MODE> [OF t, ...] [SKIP LOCKED|NOWAIT]`, or null.
def pg-lock [lock: any, lock_of: list<string>, skip_locked: bool, nowait: bool]: nothing -> any {
  if ($lock | is-empty) { return null }
  let wait = if $skip_locked { "SKIP LOCKED" } else if $nowait { "NOWAIT" } else { null }
  sql assemble [$"FOR ($lock | str uppercase)" (sql join-list $lock_of --prefix "OF ") $wait]
}

# ---- user verbs ---------------------------------------------------------------

# Run an arbitrary SQL statement against a PostgreSQL connection.
#
# The statement text is the positional <sql>, a saved `--file` (resolved under
# the query dir with a `.sql` suffix), or `$EDITOR` when neither is given. Cells
# come back LOSSLESS — every value is the string `psql` printed, uncoerced (use
# `select` when you want DB-typed rows). A statement matching the dialect danger
# regex (writes, DDL, grants, …) prompts for confirmation first, which `--yes`
# skips. The connection is the current psql one unless `--connection` names
# another; per-field flags and `--set` override individual fields.
#
# Named `raw-query`, not `run`, because `run` is a Nushell parser keyword. Reference
# invocations (leaf verb — call it as your loader exposes it, e.g. `mole-psql raw-query`):
#
#   mole-psql raw-query "SELECT now()"                                     # the current connection
#   mole-psql raw-query "SELECT id, email FROM users ORDER BY id" -c postgres-local-dev
#   mole-psql raw-query --file reports/active-users -c postgres-local-dev  # <querydir>/reports/active-users.sql
#   mole query show reports/active-users.sql | mole-psql raw-query -c postgres-local-dev  # query text piped via stdin
#   mole-psql raw-query "CREATE TEMP TABLE t (id int)" -c postgres-local-dev --yes   # skip the danger prompt
@category mole-psql
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
  let conf = (pg-conf $connection $host $port $user $password $database $set)
  let text = ($in | query resolve $sql --file $file --suffix ".sql")
  if (sql is-dangerous $text (pg-dangerous)) and (not (query confirm "This query may modify data. Run it?" --yes=$yes)) {
    return
  }
  pg-rows $conf $text
}

# Compose and run a single-table PostgreSQL SELECT, returning DB-typed rows.
#
# Every clause body — the projected columns, `--where`, `--having`, `--group-by`
# keys, `--sort-by` terms — is passed to psql VERBATIM, so expressions like
# `count(*)`, `lower(x)`, `x::int` all work; you quote reserved identifiers
# yourself. There is NO join support: the query always reads the single `--from`
# table. Flags render the postgres-specific frame around the clause bodies:
# `--distinct-on`, per-term `NULLS FIRST|LAST` in `--sort-by`, and the
# `FOR UPDATE|SHARE|NO KEY UPDATE|KEY SHARE [OF ...] [SKIP LOCKED|NOWAIT]` locks.
#
# Only the `--from` table's cached columns are DB-typed (bool/int/numeric/date/
# json → real nu values); computed and aliased columns stay strings, but
# SQL NULLs are normalized to `null` across every column (so a NULL reads the
# same here as on MySQL, not `""` vs `"NULL"`). Pass `--raw` for the untouched,
# fully lossless rows (no typing, no null-normalization). `--dry-run` returns a `{connection, query}` record — the resolved
# connection (secrets dropped) and the assembled SQL — without running it. A `--lock`
# clause locks the matched rows, so it prompts unless you pass `--yes`. Connection
# is overridable via `--connection` + per-field flags / `--set`, as in `raw-query`.
@category mole-psql
@example "every column of a table" {
  mole-psql select --from users --dry-run | get query
} --result "SELECT * FROM users"
@example "project, filter, order and limit" {
  mole-psql select id email --from users --where "age > 30" --sort-by "age desc" --limit 5 --dry-run | get query
} --result "SELECT id, email FROM users WHERE age > 30 ORDER BY age DESC LIMIT 5"
@example "DISTINCT" {
  mole-psql select status --distinct --from orders --dry-run | get query
} --result "SELECT DISTINCT status FROM orders"
@example "DISTINCT ON (postgres-specific) — first row per user" {
  mole-psql select user_id status --distinct-on [user_id] --from orders --sort-by "user_id, id desc" --dry-run | get query
} --result "SELECT DISTINCT ON (user_id) user_id, status FROM orders ORDER BY user_id, id DESC"
@example "aggregate with GROUP BY and HAVING" {
  mole-psql select user_id "count(*) AS n" --from orders --group-by [user_id] --having "count(*) > 1" --sort-by "n desc" --dry-run | get query
} --result "SELECT user_id, count(*) AS n FROM orders GROUP BY user_id HAVING count(*) > 1 ORDER BY n DESC"
@example "ORDER BY ... NULLS LAST (postgres-specific)" {
  mole-psql select name salary --from employees --sort-by "salary desc nulls last" --dry-run | get query
} --result "SELECT name, salary FROM employees ORDER BY salary DESC NULLS LAST"
@example "pagination with LIMIT + OFFSET" {
  mole-psql select --from users --sort-by id --limit 2 --offset 2 --dry-run | get query
} --result "SELECT * FROM users ORDER BY id LIMIT 2 OFFSET 2"
@example "row lock: FOR UPDATE SKIP LOCKED (needs --yes to run for real)" {
  mole-psql select --from orders --where "status = 'pending'" --lock update --skip-locked --dry-run | get query
} --result "SELECT * FROM orders WHERE status = 'pending' FOR UPDATE SKIP LOCKED"
@example "a window function passes through verbatim" {
  mole-psql select email "row_number() over (order by balance desc) AS rk" --from users --dry-run | get query
} --result "SELECT email, row_number() over (order by balance desc) AS rk FROM users"
@example "run for real — base-table columns come back DB-typed" {
  mole-psql select email is_active balance --from users --sort-by id -c postgres-local-dev
}
export def "select" [
  ...columns: string@"psql-column"                 # projected columns/expressions (default: *)
  --from(-F): string@"psql-table"                  # source table, single table only (an alias is allowed: "users u")
  --where(-w): string                              # WHERE predicate (without the keyword)
  --group-by(-g): list<string>@"psql-column"       # GROUP BY keys
  --having: string                                 # HAVING predicate (without the keyword)
  --sort-by(-s): string                            # ORDER BY terms, comma-separated: "col [asc|desc] [nulls first|last]"
  --limit(-l): int                                 # LIMIT N
  --offset(-o): int                                # OFFSET N
  --distinct                                       # SELECT DISTINCT
  --distinct-on: list<string>@"psql-column"        # SELECT DISTINCT ON (...) — postgres-specific
  --lock: string@"psql-lock"                       # row lock: update | share | no key update | key share
  --lock-of: list<string>@"psql-table"             # FOR ... OF <tables>
  --skip-locked                                    # locking wait policy (with --lock)
  --nowait                                         # locking wait policy (with --lock)
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
  if $distinct and ($distinct_on | is-not-empty) {
    error make {msg: "select: --distinct and --distinct-on are mutually exclusive"}
  }
  if $skip_locked and $nowait {
    error make {msg: "select: --skip-locked and --nowait are mutually exclusive"}
  }
  if (($lock | is-empty)) and (($lock_of | is-not-empty) or $skip_locked or $nowait) {
    error make {msg: "select: --lock-of/--skip-locked/--nowait require --lock"}
  }
  if ($from | is-empty) { error make {msg: "select: --from <table> is required"} }
  let text = (sql assemble [
    (pg-projection $columns $distinct ($distinct_on | default []))
    $"FROM ($from)"
    (if ($where | is-not-empty) { $"WHERE ($where)" })
    (sql join-list ($group_by | default []) --prefix "GROUP BY ")
    (if ($having | is-not-empty) { $"HAVING ($having)" })
    (pg-order $sort_by)
    (if $limit != null { $"LIMIT ($limit)" })
    (if $offset != null { $"OFFSET ($offset)" })
    (pg-lock $lock ($lock_of | default []) $skip_locked $nowait)
  ])
  let conf = (pg-conf $connection $host $port $user $password $database $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  # A composed SELECT can only ever read — the sole side effect it can carry is a
  # row lock, so gate the prompt on that, not on scanning the user's clause bodies.
  if ($lock | is-not-empty) and (not (query confirm "This locks the matched rows. Run it?" --yes=$yes)) {
    return
  }
  let rows = (pg-rows $conf $text)
  if $raw { return $rows }
  $rows
  | sql normalize-nulls $PG_NULLS
  | sql apply-types (sql columns-for (pg-schema-load $conf) (sql base-table $from)) {|c| pg-type $c }
}

# Inspect a connection's cached schema (introspection is cached for a day).
#
# The default view is one summary row per table: schema, name, type, column
# count, primary key, row estimate, comment. `--table` switches to the full
# detail for one table (its columns and constraints); `--find` searches table and
# column names and comments case-insensitively; `--full` returns the raw cache
# record, including its `meta`. `--refresh` rebuilds the cache from the live
# database before reading. Connection is overridable exactly as in `run`.
@category mole-psql
@example "summary — one row per table" {
  mole-psql schema -c postgres-local-dev
}
@example "detail for one table (its columns + constraints)" {
  mole-psql schema --table users -c postgres-local-dev
}
@example "search names and comments for 'balance'" {
  mole-psql schema --find balance -c postgres-local-dev
}
@example "rebuild the cache from the live database first" {
  mole-psql schema --refresh -c postgres-local-dev
}
@example "the raw cache record, including meta" {
  mole-psql schema --full -c postgres-local-dev
}
export def "schema" [
  --connection(-c): string@complete-connection   # named connection (default: current)
  --table(-t): string@"psql-table"                 # detail view for one table
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
  let conf = (pg-conf $connection $host $port $user $password $database $set)
  let data = (pg-schema-load $conf --refresh=$refresh)
  if $full { return $data }
  if ($find | is-not-empty) {
    sql schema-find $data $find
  } else if ($table | is-not-empty) {
    sql schema-detail $data $table
  } else {
    sql schema-tables $data
  }
}

# Make a psql connection the current one for this driver.
#
# Records the choice in `$env.MOLE_CURRENT.psql`, so later `run` / `select` /
# `schema` calls can omit `--connection`. Validates that `name` exists and is
# actually a psql connection (errors otherwise). Being `--env`, the change
# persists in the caller's environment.
@category mole-psql
@example "make the local dev database current" {
  mole-psql set-connection postgres-local-dev
}
export def --env "set-connection" [
  name: string@complete-connection   # a psql connection name (from the connections file)
]: nothing -> nothing {
  conn resolve $name --driver psql | ignore
  $env.MOLE_CURRENT = (($env.MOLE_CURRENT? | default {}) | upsert psql $name)
}
