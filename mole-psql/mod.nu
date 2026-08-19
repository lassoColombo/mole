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

# The mole-sql predicate-rendering dialect spec. PostgreSQL (standard_conforming_strings
# on, the default) takes `\` literally inside string literals, so no backslash escaping
# — only the universal `''` quote-doubling. Injected into `sql build-where` so the pure
# library carries no per-dialect escaping knowledge.
const PG_DIALECT = {backslash_escapes: false}

# The dialect's WHERE-operator vocabulary: the ANSI base (`= != >= <= > < ~ !~`, where
# `~`/`!~` are the universal LIKE shortcut, plus the `=null`→IS NULL and `=in:`→IN forms)
# EXTENDED with Postgres's own operators, each rendered natively and carrying a per-dialect
# completion note: `~*`/`!~*`→ILIKE, `=~`/`!=~`→POSIX regex (`~`/`!~`), `<=>`→null-safe
# equality (`IS NOT DISTINCT FROM`). Injected into every predicate-token / parse-where /
# build-where / build-having call so the operators the grammar accepts AND completes (with
# their notes) are Postgres's. Closures compose the `mole-sql` render primitives.
def "pg-ops" []: nothing -> list {
  sql ansi-ops
  | append {token: "~*",  desc: "case-insensitive LIKE (ILIKE)",     render: {|c, v, lit| sql render-like "ILIKE" $c $v $lit }}
  | append {token: "!~*", desc: "case-insensitive NOT LIKE (NOT ILIKE)", render: {|c, v, lit| sql render-like "NOT ILIKE" $c $v $lit }}
  | append {token: "=~",  desc: "regex match (~)",  render: {|c, v, lit| sql render-cmp "~" $c $v $lit }}
  | append {token: "!=~", desc: "not regex (!~)",   render: {|c, v, lit| sql render-cmp "!~" $c $v $lit }}
  | append {token: "<=>", desc: "null-safe = (IS NOT DISTINCT FROM)", render: {|c, v, lit| sql render-nullsafe "IS NOT DISTINCT FROM" $c $v $lit }}
}

# The dialect's aggregate vocabulary: the ANSI base (count/sum/avg/min/max/count-distinct)
# plus Postgres's `string_agg(col, ',')` (comma-joined string aggregation) → `string_agg_<col>`.
# Injected into `sql build-aggs` so `stats` can compute a dialect aggregate the ANSI set
# can't. Closures compose the SQL — the injection twin of `pg-ops`.
def "pg-aggs" []: nothing -> list {
  sql ansi-aggs
  | append {flag: "string_agg", fieldless: false, render: {|col| $"string_agg\(($col), ','\)" }}
}

# Map the `stats` aggregate flags (typed values in the verb, completion-time strings in
# the result-column completer) to the ordered `sql build-aggs` request list. Centralizes
# the flag→request translation so the verb body and the `--sort-by`/`--having` completers
# never drift; this order IS the SELECT output order.
def "pg-agg-requests" [count: bool, sum: string, avg: string, min: string, max: string, count_distinct: string, string_agg: string]: nothing -> list {
  [
    (if $count { [{fn: "count"}] } else { [] })
    (if ($sum | is-not-empty) { [{fn: "sum", cols: $sum}] } else { [] })
    (if ($avg | is-not-empty) { [{fn: "avg", cols: $avg}] } else { [] })
    (if ($min | is-not-empty) { [{fn: "min", cols: $min}] } else { [] })
    (if ($max | is-not-empty) { [{fn: "max", cols: $max}] } else { [] })
    (if ($count_distinct | is-not-empty) { [{fn: "count-distinct", cols: $count_distinct}] } else { [] })
    (if ($string_agg | is-not-empty) { [{fn: "string_agg", cols: $string_agg}] } else { [] })
  ] | flatten
}

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
# The catalog the command line targets. `complete catalog-ctx` resolves the
# connection robustly (typed -c → current → cached), reads/builds the schema via
# pg-schema-load (a cache miss introspects the live DB once, then serves cached),
# and never throws — an empty catalog just yields no candidates.
def psql-catalog [context: string]: nothing -> record {
  complete catalog-ctx $context psql --get {|c| pg-schema-load $c }
}

def "psql-table" [context: string]: nothing -> list<string> {
  sql complete-tables (psql-catalog $context)
}

# Comma-list variant for the `schema --include/--exclude` filters: re-prepend the
# already-typed tables so accepting a candidate extends the list.
def "psql-tables-csv" [context: string]: nothing -> list<string> {
  let prefix = (complete token $context | str replace --regex '[^,]*$' '')
  sql complete-tables (psql-catalog $context) | each {|t| $"($prefix)($t)" }
}

def "psql-column" [context: string]: nothing -> list<string> {
  # `select` names its table with --from; `update`/`delete` take it as the leading
  # positional — fall back to that so column completion works for the write verbs too.
  let tbl = (complete flag $context [--from -F] | default (sql lead-arg $context [update delete]))
  sql complete-columns (psql-catalog $context) $tbl
}

# Comma-list variant of `psql-column` for the multi-value column flags (`--distinct-on`,
# `--returning`, and `stats`' `--by`/`--sum`/`--avg`/…): re-prepend the already-typed
# columns so accepting a candidate extends the list (Nushell can't complete inside a
# `[...]` list literal).
def "psql-columns-csv" [context: string]: nothing -> list<string> {
  let prefix = (complete token $context | str replace --regex '[^,]*$' '')
  psql-column $context | each {|c| $"($prefix)($c)" }
}

# `select`'s `--sort-by` completer: the source columns as `col[:desc]` sort tokens.
def "psql-sort" [context: string]: nothing -> list<string> { complete sort-csv $context (psql-column $context) }

# Completion-only bounded/quiet distinct-value probe: a read-only SELECT run with a
# short connect + statement timeout and no password prompt (`-w`), returning the `v`
# column's values (empty on any non-zero exit). Kept separate from `pg-exec` so the
# verbs' exec path is untouched; the caller wraps it in `try` for parse errors.
def pg-probe [conf: record, sql: string]: nothing -> list<string> {
  let db = ($conf | get -o database)
  let db_args = if ($db | is-not-empty) { ["-d" $db] } else { [] }
  let r = (with-env {
    PGPASSWORD: ($conf | get -o password | default "")
    PGCONNECT_TIMEOUT: "3"
    PGOPTIONS: "-c statement_timeout=3000"
  } {
    ^psql -w -h ($conf | get -o host) -p ($conf | get -o port | default 5432) -U ($conf | get -o user) ...$db_args --csv -q -c $sql | complete
  })
  if ($r.exit_code != 0) { return [] }
  $r.stdout | from csv --no-infer | get -o v | default []
}

# `--where` completer: the dialect predicate completer, csv-aware (like `psql-having`).
# `--where` holds a comma-list of `col<op>value` tokens; this completes the LAST segment
# and re-prepends the earlier ones. Three stages: a partial segment completes column
# NAMES; a COMPLETE column completes into the dialect OPERATORS (`col=`, `col~*`, … via
# `op-completions` — so you never type `=` by hand); an `=`/`!=` segment then runs a
# LIVE, bounded `SELECT DISTINCT <col>` — scoped to the sibling predicates already
# committed in the flag and the `--from`/leading table — offering `col<op>value` for each
# distinct value (best-effort: unreachable/slow/errored → nothing). Comparison/LIKE/`in:`
# complete nothing further; a bare segment right after an open `in:` list also completes
# nothing (so typing more in-list values isn't drowned in column names).
def "psql-where" [context: string]: nothing -> list<any> {
  let ops = (pg-ops)
  let tok = (complete token $context)
  let prefix = ($tok | str replace --regex '[^,]*$' '')       # everything up to & incl the last comma
  let seg = ($tok | split row "," | last | default "")         # the segment being typed
  let committed = ($prefix | str trim --char ",")
  let pref_preds = (sql parse-where $committed --ops $ops)      # sibling predicates (null if the committed part is raw)
  let p = (sql predicate-token $seg --ops $ops)
  # mid open-in:-list — a bare segment after an in:-valued predicate ⇒ don't offer columns
  if ($p == null) and ($pref_preds != null) and ($pref_preds | is-not-empty) and (($pref_preds | last | get value) | str starts-with "in:") {
    return []
  }
  if ($p == null) {
    let cols = (psql-column $context)
    if ($seg in $cols) {
      # exact column → the dialect operators (+ any longer columns sharing the prefix)
      let longer = ($cols | where {|c| $c != $seg and ($c | str starts-with $seg) } | each {|c| {value: ($prefix + $c), description: "column"} })
      return (((sql op-completions $seg $ops) | each {|r| {value: ($prefix + $r.value), description: $r.description} }) ++ $longer)
    }
    return ($cols | each {|c| $prefix + $c })
  }
  if ($p.op not-in ["=" "!="]) or ($p.value | str starts-with "in:") { return [] }
  let table = (complete flag $context [--from -F] | default (sql lead-arg $context [update delete]))
  let conf = (complete conn-ctx $context "psql")
  if ($table | is-empty) or ($conf | is-empty) { return [] }
  # The probe SELECT frame (incl. LIMIT) is the driver's — mole-sql only composes the WHERE.
  let siblings = (if ($pref_preds == null) { [] } else { $pref_preds | where col != $p.col })
  let where = (sql render-where $siblings --dialect $PG_DIALECT --ops $ops)
  let q = (sql assemble [
    $"SELECT DISTINCT ($p.col) AS v FROM ($table)"
    (if ($where | is-not-empty) { $"WHERE ($where)" })
    "LIMIT 50"
  ])
  (try { pg-probe $conf $q } catch { [] }) | each {|v| $prefix + $p.col + $p.op + $v }
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
  if (query is-dangerous $text (pg-dangerous)) and (not (query confirm "This query may modify data. Run it?" --yes=$yes)) {
    return
  }
  pg-rows $conf $text
}

# Compose and run a single-table PostgreSQL SELECT, returning DB-typed rows.
#
# Single-table ROW retrieval — projection, filter, order, paging, DISTINCT, and locks.
# NO aggregation (reach for `stats`) and NO joins (reach for `raw-query`). The projected
# columns are the rest slot (`id email`, `lower(x)`, `x::int`; commas optional, default
# `*`), passed to psql VERBATIM — you quote reserved identifiers yourself.
#
# The WHERE clause is `--where`, DUAL-MODE: a comma-separated `col<op>value` token-list
# (`status=active,age>=30`, `name~%acme%`, `role=in:admin,ops`, `deleted=null`) whose
# columns AND operators tab-complete; or — when it doesn't parse as tokens — raw SQL
# passed through verbatim (an `OR`, a sub-select, `now()`, spaced operators). Token
# operators are `= != > >= < <=`, `~`/`!~` (LIKE / NOT LIKE), and the `=null` / `=in:`
# forms; the value is quoted by shape (numbers/bools bare, else a string literal).
# `--sort-by` orders by `col[:desc]` tokens (a bare column is ASC); `NULLS FIRST|LAST`
# and expression ordering are a `raw-query`. Postgres-specific frame: `--distinct-on`
# and the `FOR UPDATE|SHARE|NO KEY UPDATE|KEY SHARE [OF ...] [SKIP LOCKED|NOWAIT]` locks.
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
  mole-psql select id email --from users --where "age > 30" --sort-by age:desc --limit 5 --dry-run | get query
} --result "SELECT id, email FROM users WHERE age > 30 ORDER BY age DESC LIMIT 5"
@example "DISTINCT" {
  mole-psql select status --distinct --from orders --dry-run | get query
} --result "SELECT DISTINCT status FROM orders"
@example "DISTINCT ON (postgres-specific) — first row per user" {
  mole-psql select user_id status --distinct-on user_id --from orders --sort-by user_id,id:desc --dry-run | get query
} --result "SELECT DISTINCT ON (user_id) user_id, status FROM orders ORDER BY user_id, id DESC"
@example "pagination with LIMIT + OFFSET" {
  mole-psql select --from users --sort-by id --limit 2 --offset 2 --dry-run | get query
} --result "SELECT * FROM users ORDER BY id LIMIT 2 OFFSET 2"
@example "row lock: FOR UPDATE SKIP LOCKED (needs --yes to run for real)" {
  mole-psql select --from orders --where "status = 'pending'" --lock update --skip-locked --dry-run | get query
} --result "SELECT * FROM orders WHERE status = 'pending' FOR UPDATE SKIP LOCKED"
@example "a window function passes through verbatim" {
  mole-psql select email "row_number() over (order by balance desc) AS rk" --from users --dry-run | get query
} --result "SELECT email, row_number() over (order by balance desc) AS rk FROM users"
@example "a --where token-list composes the WHERE clause (columns + operators complete)" {
  mole-psql select id email --from users --where status=active,age>=30 --dry-run | get query
} --result "SELECT id, email FROM users WHERE status = 'active' AND age >= 30"
@example "--where falls back to raw SQL when it isn't a token-list" {
  mole-psql select --from orders --where "total > 0 AND status <> 'void'" --dry-run | get query
} --result "SELECT * FROM orders WHERE total > 0 AND status <> 'void'"
@example "IN, LIKE and NULL predicate forms in one --where token-list" {
  mole-psql select --from users --where role=in:admin,ops,name~%acme%,deleted=null --dry-run | get query
} --result "SELECT * FROM users WHERE role IN ('admin', 'ops') AND name LIKE '%acme%' AND deleted IS NULL"
@example "run for real — base-table columns come back DB-typed" {
  mole-psql select email is_active balance --from users --sort-by id -c postgres-local-dev
}
export def "select" [
  ...columns: string@"psql-column"                 # projected columns (default: *); commas are optional and trimmed
  --from(-F): string@"psql-table"                  # source table, single table only (an alias is allowed: "users u")
  --where(-w): string@"psql-where"                 # WHERE: col<op>value token-list (comma-sep, completable) OR raw SQL
  --sort-by(-s): string@"psql-sort"                # ORDER BY terms: col[:desc], comma-separated
  --limit(-l): int                                 # LIMIT N
  --offset(-o): int                                # OFFSET N
  --distinct                                       # SELECT DISTINCT
  --distinct-on: string@"psql-columns-csv"         # SELECT DISTINCT ON (...), comma-separated — postgres-specific
  --lock: string@"psql-lock"                       # row lock: update | share | no key update | key share
  --lock-of: string@"psql-tables-csv"              # FOR ... OF <tables>, comma-separated
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
  # Multi-value flags arrive as ONE comma-joined string (Nushell can't complete inside a
  # `[...]` literal); decode to the list the clause renderers want, shadowing the params.
  let distinct_on = (sql csv-split $distinct_on)
  let lock_of = (sql csv-split $lock_of)
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
  # The rest slot is projection-only now (commas optional); WHERE lives in --where,
  # dual-mode: a col<op>value token-list, or raw SQL when it doesn't parse as tokens.
  let cols = ($columns | each {|c| $c | str trim --char "," } | where {|c| $c | is-not-empty })
  let where_sql = (sql build-where ($where | default "") --dialect $PG_DIALECT --ops (pg-ops))
  let text = (sql assemble [
    (pg-projection $cols $distinct ($distinct_on | default []))
    $"FROM ($from)"
    (if ($where_sql | is-not-empty) { $"WHERE ($where_sql)" })
    (sql build-order (sql csv-split $sort_by))
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

# ---- stats completers (result-column pool) ------------------------------------
# The RESULT columns of a `stats` line: the `--by` keys ++ the aggregate auto-names,
# reconstructed from the flags on the line via the SAME `sql build-aggs` the verb body
# uses (so completion and the generated SQL never drift — the `vl-stat-cols` pattern).
# No I/O: the aggregate names come from the flags, not the schema, so this completes
# even without a reachable database.
def "psql-result-cols" [context: string]: nothing -> list<string> {
  let by = (complete csv (complete flag $context [--by -g]))
  let requests = (pg-agg-requests
    ($context =~ '(?:--count|-C)(?:\s|$)')
    (complete flag $context [--sum] | default "")
    (complete flag $context [--avg] | default "")
    (complete flag $context [--min] | default "")
    (complete flag $context [--max] | default "")
    (complete flag $context [--count-distinct] | default "")
    (complete flag $context [--string-agg] | default ""))
  $by ++ ((sql build-aggs $requests (pg-aggs)) | get name)
}

# `--having` completer: partial two-stage — complete the RESULT-column name; once an
# operator is typed the user fills the value (like mongo's `--having`). Comma-list aware.
def "psql-having" [context: string]: nothing -> list<string> {
  let tok = (complete token $context)
  let seg = ($tok | split row "," | last)
  if (sql predicate-token $seg --ops (pg-ops)) != null { return [] }
  let prefix = ($tok | str replace --regex '[^,]*$' '')
  psql-result-cols $context | each {|c| $"($prefix)($c)" }
}

# `--sort-by` completer over RESULT columns (`col[:desc]`), via the shared sort helper.
def "psql-rsort" [context: string]: nothing -> list<string> { complete sort-csv $context (psql-result-cols $context) }

# Compose and run a single-table PostgreSQL aggregation (GROUP BY), returning typed rows.
#
# The analytics twin of `select`: `stats` groups by `--by` keys and computes the
# per-function aggregate flags (`--count`, `--sum`, `--avg`, `--min`, `--max`,
# `--count-distinct`), each auto-named SQL-style (`count`, `sum_<col>`, `avg_<col>`,
# `count_distinct_<col>`). `--where` is the PRE-aggregation filter — the same dual-mode
# `col<op>value` token-list-or-raw-SQL as `select`. `--having`
# filters the grouped rows with the same token grammar but over the RESULT columns
# (`count>=10`, `sum_amount>1000`) — the alias is expanded back to its aggregate
# expression, so it is portable across dialects; `count` is always available. `--sort-by`
# orders the RESULT columns (`col[:desc]`), and `--limit`/`--offset` page them.
#
# No `--by` yields a grand total (one row); no aggregate flag defaults to `count(*)`.
# Group keys come back DB-typed from the schema; `count`/`count_distinct` are ints and
# `avg`/`sum` floats (`min`/`max` keep the source string unless you `--raw`). `--dry-run`
# returns `{connection, query}`. Aggregations only READ, so there is no prompt.
# Anything past this subset — joins, expression aggregates, GROUPING SETS, windows,
# percentiles — is a `raw-query`. Connection overridable as in `raw-query`.
@category mole-psql
@example "count and sum per group, ordered, top-N" {
  mole-psql stats --from orders --by region --count --sum amount --sort-by sum_amount:desc --limit 10 --dry-run | get query
} --result "SELECT region, count(*) AS count, sum(amount) AS sum_amount FROM orders GROUP BY region ORDER BY sum_amount DESC LIMIT 10"
@example "pre-filter + HAVING over result columns (alias expands to the expression)" {
  mole-psql stats --from orders --by region,tier --count --avg amount --where status=active --having count>=10 --sort-by avg_amount:desc --dry-run | get query
} --result "SELECT region, tier, count(*) AS count, avg(amount) AS avg_amount FROM orders WHERE status = 'active' GROUP BY region, tier HAVING count(*) >= 10 ORDER BY avg_amount DESC"
@example "grand total — no --by" {
  mole-psql stats --from orders --count --sum amount --dry-run | get query
} --result "SELECT count(*) AS count, sum(amount) AS sum_amount FROM orders"
@example "distinct customers per region" {
  mole-psql stats --from orders --by region --count-distinct customer_id --dry-run | get query
} --result "SELECT region, count(distinct customer_id) AS count_distinct_customer_id FROM orders GROUP BY region"
@example "a Postgres dialect aggregate — comma-joined names per region" {
  mole-psql stats --from users --by region --string-agg name --dry-run | get query
} --result "SELECT region, string_agg(name, ',') AS string_agg_name FROM users GROUP BY region"
@example "run for real — grouped rows come back DB-typed" {
  mole-psql stats --from orders --by region --count --avg amount -c postgres-local-dev
}
export def "stats" [
  --from(-F): string@"psql-table"                  # source table, single table only (an alias is allowed: "users u")
  --where(-w): string@"psql-where"                 # WHERE: col<op>value token-list (comma-sep, completable) OR raw SQL (pre-aggregation)
  --by(-g): string@"psql-columns-csv"              # GROUP BY keys, comma-separated
  --count(-C)                                      # count(*) → `count`
  --sum: string@"psql-columns-csv"                 # sum(col) → `sum_<col>`, comma-separated columns
  --avg: string@"psql-columns-csv"                 # avg(col) → `avg_<col>`
  --min: string@"psql-columns-csv"                 # min(col) → `min_<col>`
  --max: string@"psql-columns-csv"                 # max(col) → `max_<col>`
  --count-distinct: string@"psql-columns-csv"      # count(distinct col) → `count_distinct_<col>`
  --string-agg: string@"psql-columns-csv"          # string_agg(col, ',') → `string_agg_<col>` (Postgres dialect aggregate)
  --having: string@"psql-having"                   # post-aggregation filter tokens over RESULT columns (AND-joined)
  --sort-by(-s): string@"psql-rsort"               # ORDER BY over RESULT columns: col[:desc], comma-separated
  --limit(-l): int                                 # LIMIT N
  --offset(-o): int                                # OFFSET N
  --connection(-c): string@complete-connection   # named connection (default: current)
  --host(-h): string
  --port(-p): int
  --user(-u): string
  --password(-P): string
  --database(-d): string
  --set: record = {}
  --raw(-R)                                         # raw driver output: no typing, no null-normalization
  --dry-run(-n)                                    # return a {connection, query} record instead of running
] {
  if ($from | is-empty) { error make {msg: "stats: --from <table> is required"} }
  let by = (sql csv-split $by)
  let aggs = (sql build-aggs (pg-agg-requests $count ($sum | default "") ($avg | default "") ($min | default "") ($max | default "") ($count_distinct | default "") ($string_agg | default "")) (pg-aggs))
  # --where is dual-mode: a col<op>value token-list, or raw SQL when it doesn't parse.
  let where_sql = (sql build-where ($where | default "") --dialect $PG_DIALECT --ops (pg-ops))
  let proj = (($by ++ ($aggs | each {|a| $a.expr + " AS " + $a.name })) | str join ", ")
  let text = (sql assemble [
    $"SELECT ($proj)"
    $"FROM ($from)"
    (if ($where_sql | is-not-empty) { $"WHERE ($where_sql)" })
    (sql join-list $by --prefix "GROUP BY ")
    (sql build-having (sql csv-split $having) $aggs --dialect $PG_DIALECT --ops (pg-ops))
    (sql build-order (sql csv-split $sort_by))
    (if $limit != null { $"LIMIT ($limit)" })
    (if $offset != null { $"OFFSET ($offset)" })
  ])
  let conf = (pg-conf $connection $host $port $user $password $database $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  let rows = (pg-rows $conf $text)
  if $raw { return $rows }
  $rows
  | sql normalize-nulls $PG_NULLS
  | sql apply-types (sql columns-for (pg-schema-load $conf) (sql base-table $from)) {|c| pg-type $c }
  | sql apply-agg-types $aggs
}

# Compose and run a single-table PostgreSQL UPDATE.
#
# Reads like the statement: `update <table> <assignment>...`. The table is the
# leading positional (completing table names); the SET assignments follow as
# positionals — each a verbatim `"col = expr"`, so expressions (`hits = hits + 1`,
# `updated_at = now()`) all work; you quote identifiers and string literals
# yourself, and their column names complete against the table. `--where` is the
# same dual-mode `col<op>value` token-list-or-raw-SQL predicate as `select`;
# `--returning` names columns to hand back for
# the changed rows (Postgres RETURNING), typed exactly like a `select` result.
# There is NO join support — the target is the single table; reach for `raw-query`
# for `UPDATE ... FROM`.
#
# UPDATE always writes, so it prompts before running (skip with `--yes`) and
# REFUSES to touch every row unless you pass `--all` (a missing `--where` would
# otherwise rewrite the whole table). `--dry-run` returns a `{connection, query}`
# record without running. Connection overridable via `--connection` + per-field
# flags / `--set`, as in `raw-query`.
@category mole-psql
@example "set a column on the matched rows" {
  mole-psql update users "status = 'inactive'" --where "last_login < now() - interval '1 year'" --dry-run | get query
} --result "UPDATE users SET status = 'inactive' WHERE last_login < now() - interval '1 year'"
@example "expression assignment, returning the new value" {
  mole-psql update users "login_count = login_count + 1" --where "id = 42" --returning id,login_count --dry-run | get query
} --result "UPDATE users SET login_count = login_count + 1 WHERE id = 42 RETURNING id, login_count"
@example "several assignments at once" {
  mole-psql update users "status = 'active'" "verified = true" --where "email = 'a@b.c'" --dry-run | get query
} --result "UPDATE users SET status = 'active', verified = true WHERE email = 'a@b.c'"
@example "guard: an unfiltered UPDATE needs --all" {
  mole-psql update users "archived = true" --all --dry-run | get query
} --result "UPDATE users SET archived = true"
@example "run for real — RETURNING rows come back DB-typed (prompts unless --yes)" {
  mole-psql update accounts "balance = balance - 10" --where "id = 1" --returning id,balance -c postgres-local-dev --yes
}
export def "update" [
  table: string@"psql-table"                       # target table (UPDATE <table>); single table, an alias is allowed: "users u"
  ...assignments: string@"psql-column"             # SET assignments, verbatim "col = expr" (at least one required)
  --where(-w): string@"psql-where"                 # WHERE: col<op>value token-list (comma-sep, completable) OR raw SQL
  --returning: string@"psql-columns-csv"           # RETURNING columns, comma-separated (typed like a select result)
  --all                                            # allow an unfiltered UPDATE (every row) when --where is omitted
  --connection(-c): string@complete-connection   # named connection (default: current)
  --host(-h): string
  --port(-p): int
  --user(-u): string
  --password(-P): string
  --database(-d): string
  --set: record = {}
  --raw(-R)                                         # raw driver output for RETURNING rows: no typing, no null-normalization
  --dry-run(-n)                                    # return a {connection, query} record instead of running
  --yes(-y)                                         # skip the confirmation prompt
] {
  if ($assignments | is-empty) { error make {msg: "update: at least one SET assignment is required, e.g. update users \"status = 'active'\""} }
  if ($where | is-empty) and (not $all) {
    error make {msg: "update: refusing to update every row without --where (pass --all to override)"}
  }
  let returning = (sql csv-split $returning)   # comma-joined string → list (Nushell can't complete inside `[...]`)
  # --where is dual-mode: a col<op>value token-list, or raw SQL when it doesn't parse.
  let where_sql = (sql build-where ($where | default "") --dialect $PG_DIALECT --ops (pg-ops))
  let text = (sql build-update --table $table --set $assignments --where ($where_sql | default "") --returning ($returning | default []))
  let conf = (pg-conf $connection $host $port $user $password $database $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (not (query confirm "This UPDATE will modify rows. Run it?" --yes=$yes)) { return }
  let rows = (pg-rows $conf $text)
  if $raw or ($rows | is-empty) { return $rows }
  $rows
  | sql normalize-nulls $PG_NULLS
  | sql apply-types (sql columns-for (pg-schema-load $conf) (sql base-table $table)) {|c| pg-type $c }
}

# Compose and run a single-table PostgreSQL DELETE.
#
# Reads like the statement: `delete <table> --where <predicate>`. The table is the
# leading positional (completing table names); `--where` is DUAL-MODE — a comma-
# separated `col<op>value` token-list (`user_id=7`, `status=inactive`, `role=in:a,b`,
# `deleted=null`) whose columns and operators complete, or raw SQL (an `OR`, `now()`,
# a sub-select) when it doesn't parse — the same grammar as `select`. `--returning` names columns to hand
# back for the deleted rows (Postgres RETURNING), typed exactly like a `select`
# result. There is NO join support — deletes from the single table; reach for
# `raw-query` for `DELETE ... USING`.
#
# DELETE always writes, so it prompts before running (skip with `--yes`) and
# REFUSES to delete every row unless you pass `--all`. `--dry-run` returns a
# `{connection, query}` record without running. Connection overridable as in
# `raw-query`.
@category mole-psql
@example "a --where token-list builds the filter (columns + operators complete)" {
  mole-psql delete sessions --where user_id=7 --dry-run | get query
} --result "DELETE FROM sessions WHERE user_id = 7"
@example "an expression filter uses the raw --where" {
  mole-psql delete sessions --where "expires_at < now()" --dry-run | get query
} --result "DELETE FROM sessions WHERE expires_at < now()"
@example "delete, returning everything that was removed" {
  mole-psql delete sessions --where "user_id = 7" --returning "*" --dry-run | get query
} --result "DELETE FROM sessions WHERE user_id = 7 RETURNING *"
@example "guard: an unfiltered DELETE needs --all" {
  mole-psql delete staging_rows --all --dry-run | get query
} --result "DELETE FROM staging_rows"
@example "run for real — returns the deleted ids (prompts unless --yes)" {
  mole-psql delete sessions --where "user_id = 7" --returning id -c postgres-local-dev --yes
}
export def "delete" [
  table: string@"psql-table"                       # target table (DELETE FROM <table>); single table, an alias is allowed: "users u"
  --where(-w): string@"psql-where"                 # WHERE: col<op>value token-list (comma-sep, completable) OR raw SQL
  --returning: string@"psql-columns-csv"           # RETURNING columns, comma-separated (typed like a select result)
  --all                                            # allow an unfiltered DELETE (every row) when --where is omitted
  --connection(-c): string@complete-connection   # named connection (default: current)
  --host(-h): string
  --port(-p): int
  --user(-u): string
  --password(-P): string
  --database(-d): string
  --set: record = {}
  --raw(-R)                                         # raw driver output for RETURNING rows: no typing, no null-normalization
  --dry-run(-n)                                    # return a {connection, query} record instead of running
  --yes(-y)                                         # skip the confirmation prompt
] {
  # --where is dual-mode: a col<op>value token-list, or raw SQL when it doesn't parse.
  let where_sql = (sql build-where ($where | default "") --dialect $PG_DIALECT --ops (pg-ops))
  if ($where_sql | is-empty) and (not $all) {
    error make {msg: "delete: refusing to delete every row without --where (pass --all to override)"}
  }
  let returning = (sql csv-split $returning)   # comma-joined string → list (Nushell can't complete inside `[...]`)
  let text = (sql build-delete --table $table --where ($where_sql | default "") --returning ($returning | default []))
  let conf = (pg-conf $connection $host $port $user $password $database $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (not (query confirm "This DELETE will remove rows. Run it?" --yes=$yes)) { return }
  let rows = (pg-rows $conf $text)
  if $raw or ($rows | is-empty) { return $rows }
  $rows
  | sql normalize-nulls $PG_NULLS
  | sql apply-types (sql columns-for (pg-schema-load $conf) (sql base-table $table)) {|c| pg-type $c }
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
@example "render only the core tables as a Mermaid ER diagram" {
  mole-psql schema --full --include "users,orders,order_items" -c postgres-local-dev | mole-mermaid er-schema
}
@example "dump everything except housekeeping tables" {
  mole-psql schema --full --exclude "*_audit,django_*" -c postgres-local-dev
}
export def "schema" [
  --connection(-c): string@complete-connection   # named connection (default: current)
  --table(-t): string@"psql-table"                 # detail view for one table
  --find: string                                   # find tables/columns by name or comment (case-insensitive)
  --refresh(-r)                                    # rebuild the cache before reading
  --full                                           # return the full cache record
  --include: string@"psql-tables-csv"              # keep ONLY these tables — comma-sep names/globs (mutually exclusive with --exclude)
  --exclude: string@"psql-tables-csv"              # drop these tables — comma-sep names/globs (mutually exclusive with --include)
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
  let conf = (pg-conf $connection $host $port $user $password $database $set)
  let data = (sql schema-filter (pg-schema-load $conf --refresh=$refresh) --include (sql csv-split $include) --exclude (sql csv-split $exclude))
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
  conn set-current psql $name | ignore
}
