# mole-duckdb — DuckDB driver plugin.
#
# A PLUGIN (data source): supports the duckdb technology, registers itself as a
# driver, and exposes the user verbs `raw-query` / `select` / `schema`. It DEPENDS on:
#   - mole core plumbing        (`use mole/lib/*.nu`)
#   - the generic mole-sql pure LIBRARY (`use mole-sql/sql.nu`)
# The mole-sql library must be reachable via `NU_LIB_DIRS`.
#
# LAYERING: everything driver-specific (how to invoke duckdb, the introspection
# SQL, the type map, the danger regex) and all orchestration (resolve → exec →
# check → parse → cache → type) lives HERE. The library only ever receives data
# and closures. Modeled on mole-psql, differing in these private dialect pieces.
#
# EMBEDDED: DuckDB has no server. A connection is a FILE PATH (`path`, or
# `database`), defaulting to `:memory:` — there is NO host/port/user, so
# duck-exec/duck-conf handle a connection record without those fields, and the
# `select` verb omits psql's row-locking clauses (DuckDB has none).

use mole/lib/conn.nu

# Driver-scoped connection completer: only THIS driver (duckdb), never other drivers.
def "complete-connection" []: nothing -> list<string> { conn names "duckdb" }
use mole/lib/cache.nu
use mole/lib/query.nu
use mole/lib/complete.nu
use mole-sql/sql.nu

export-env {
  conn register "duckdb"
}

# ---- dialect specifics (duckdb) ----------------------------------------------

# How `duckdb -csv` renders a SQL NULL: the literal text `NULL` (an empty field
# is a genuine empty string). Injected into the mole-sql normalizers so the pure
# library carries no knowledge of how this dialect spells NULL.
const DUCK_NULLS = ["NULL"]

# The mole-sql predicate-rendering dialect spec. DuckDB follows PostgreSQL: `\` is
# literal inside string literals (verified: `SELECT length('a\b')` is 3), so no
# backslash escaping — only the universal `''` quote-doubling.
const DUCK_DIALECT = {backslash_escapes: false}

# Statements that warrant a confirmation prompt before running.
def duck-dangerous []: nothing -> string {
  '(?i)\b(delete|drop|truncate|update|insert|copy|create|alter|rename|grant|revoke|analyze|vacuum|reindex|checkpoint|commit|rollback|begin|start|attach|detach|prepare|deallocate|execute|call|export|import|install|load|set|reset|pragma|use)\b'
}

# The connection's database file: `path`, then `database`, else `:memory:`.
# DuckDB is embedded — there is no host/port/user.
def duck-path [conf: record]: nothing -> string {
  $conf | get -o path | default ($conf | get -o database) | default ":memory:"
}

# Run one SQL statement against the file DB, returning a `complete` record.
# Output as CSV so it parses losslessly (DuckDB renders NULL as the literal
# `NULL` and empty strings as empty; `sql normalize-nulls $DUCK_NULLS` turns the
# `NULL` placeholder into a real null downstream).
#
# DuckDB is embedded and takes an EXCLUSIVE file lock in read-write mode, so two
# `duckdb` processes on one file collide. `--readonly` opens the file read-only,
# which DOES allow concurrent readers — the schema loader relies on this to run
# its introspection queries in parallel (see `duck-schema-load`).
def duck-exec [conf: record, sql: string, --readonly]: nothing -> record {
  let ro = if $readonly { ["-readonly"] } else { [] }
  ^duckdb (duck-path $conf) ...$ro -csv -c $sql | complete
}

# Exec + check + lossless parse (every cell stays a string).
def duck-rows [conf: record, sql: string, --readonly]: nothing -> any {
  duck-exec $conf $sql --readonly=$readonly | query check | from csv --no-infer
}

# data_type → cell-converter closure (or null to leave the column as-is).
# Matches DuckDB's information_schema `data_type` spellings (UPPERCASE; DECIMAL
# and its variants carry inline precision e.g. `DECIMAL(10,2)`, so match by
# prefix). Verified against DuckDB 1.5.
def duck-type [col: record]: nothing -> any {
  let dt = ($col | get -o data_type | default "" | into string | str uppercase)
  let base = ($dt | split row "(" | first | str trim)   # strip inline (p,s) / (n)
  match $base {
    "BOOLEAN" | "BOOL" => (sql null-or {|x| ($x | str lowercase) in ["t" "true" "yes" "1"] })
    "TINYINT" | "SMALLINT" | "INTEGER" | "BIGINT" | "HUGEINT"
      | "UTINYINT" | "USMALLINT" | "UINTEGER" | "UBIGINT" | "UHUGEINT" => (sql null-or {|x| $x | into int })
    "REAL" | "FLOAT" | "DOUBLE" | "DECIMAL" | "NUMERIC" => (sql null-or {|x| $x | into float })
    "DATE" | "TIMESTAMP" | "TIMESTAMPTZ"
      | "TIMESTAMP WITH TIME ZONE" | "TIMESTAMP_NS" | "TIMESTAMP_MS" | "TIMESTAMP_S"
      | "DATETIME" => (sql null-or {|x| $x | into datetime })
    "JSON" => (sql null-or {|x| $x | from json })
    _ => null
  }
}

# Friendly column type. DuckDB's `data_type` already carries size/precision
# (e.g. `DECIMAL(10,2)`), and `character_maximum_length` is NULL even for
# VARCHAR(n) — so the reported `data_type` IS the display type. Fall back to the
# psql-style synthesis only if a length/precision is unexpectedly present.
def duck-display-type [c: record]: nothing -> string {
  let base = ($c.data_type | into string)
  if ($base | str contains "(") { return $base }
  let l = ($c | get -o char_max_length)
  if $l != null { return $"($base)\(($l))" }
  let p = ($c | get -o numeric_precision)
  if $p != null and (($base | str uppercase) in ["DECIMAL" "NUMERIC"]) {
    let s = ($c | get -o numeric_scale | default 0)
    return $"($base)\(($p),($s))"
  }
  $base
}

# Tables (and views): type + comment from information_schema, row estimate from
# duckdb_tables() (information_schema has no row count). Excludes system schemas.
def duck-tables-sql []: nothing -> string {
  r#'
    SELECT
      t.table_schema AS "schema",
      t.table_name AS "name",
      t.table_type AS "type",
      t.TABLE_COMMENT AS "comment",
      dt.estimated_size AS "row_estimate"
    FROM information_schema.tables t
    LEFT JOIN duckdb_tables() dt
      ON dt.schema_name = t.table_schema AND dt.table_name = t.table_name
    WHERE t.table_schema NOT IN ('information_schema', 'pg_catalog')
    ORDER BY t.table_schema, t.table_name
  '#
}

# Columns: information_schema.columns carries data_type (with inline precision),
# udt_name, is_nullable ("YES"/"NO"), column_default, and COLUMN_COMMENT.
def duck-columns-sql []: nothing -> string {
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
      c.COLUMN_COMMENT AS "comment"
    FROM information_schema.columns c
    WHERE c.table_schema NOT IN ('information_schema', 'pg_catalog')
    ORDER BY c.table_schema, c.table_name, c.ordinal_position
  '#
}

# Constraints via duckdb_constraints(): PK / FK / UNIQUE (NOT NULL and CHECK are
# skipped — they aren't multi-column keys). The column-name lists are VARCHAR[],
# so `array_to_string(..., ',')` renders them for `sql normalize-constraints` to
# re-split. DuckDB exposes no referenced *schema*, so ref_schema mirrors the
# constraint's own schema (FKs are within one database file).
def duck-constraints-sql []: nothing -> string {
  r#'
    SELECT
      schema_name AS "schema",
      table_name AS "table",
      constraint_name AS "name",
      constraint_type AS "type",
      array_to_string(constraint_column_names, ',') AS "columns",
      CASE WHEN constraint_type = 'FOREIGN KEY' THEN schema_name END AS "ref_schema",
      referenced_table AS "ref_table",
      array_to_string(referenced_column_names, ',') AS "ref_columns"
    FROM duckdb_constraints()
    WHERE constraint_type IN ('PRIMARY KEY', 'FOREIGN KEY', 'UNIQUE')
      AND schema_name NOT IN ('information_schema', 'pg_catalog')
    ORDER BY schema_name, table_name, constraint_type, constraint_index
  '#
}

# ---- orchestration ------------------------------------------------------------

# Load the schema cache for a connection, rebuilding when --refresh or stale.
# Cache key is `<name>__<db-or-path-basename>` so distinct files don't collide.
def duck-schema-load [conf: record, --refresh]: nothing -> record {
  let dbkey = (duck-path $conf | path basename)
  let file = (cache path "duckdb" $"($conf.name)__($dbkey)")
  if $refresh or (cache stale $file 1day) {
    let secs = [
        {k: "tables"      q: (duck-tables-sql)}
        {k: "columns"     q: (duck-columns-sql)}
        {k: "constraints" q: (duck-constraints-sql)}
      ]
      | par-each {|s| {key: $s.k, rows: (duck-rows $conf $s.q --readonly)} }
      | reduce --fold {} {|it, acc| $acc | upsert $it.key $it.rows }
    let body = (sql schema-body $secs.tables $secs.columns $secs.constraints {|c| duck-display-type $c } $DUCK_NULLS)
    let data = ({meta: {connection: $conf.name, database: (duck-path $conf), driver: "duckdb", refreshed_at: (date now)}} | merge $body)
    $data | cache write $file
    return $data
  }
  cache read $file
}

# The standard override record: named flags win over the resolved connection,
# and --set wins over the named flags (for arbitrary/driver-specific fields).
# `path` is DuckDB's connection target (the database file) — expose it as its own
# flag as well as via --set.
def duck-conf [
  connection: any, path: any, database: any, set: record
]: nothing -> record {
  conn with duckdb $connection ({
    path: $path, database: $database
  } | merge $set)
}

# ---- completers (cache-backed; build the schema on a cache miss) --------------
# These call duck-schema-load, so a first completion against a not-yet-cached (or
# day-stale) connection introspects the database once, then serves from cache.

def duckdb-catalog [context: string]: nothing -> record {
  complete catalog-ctx $context duckdb --get {|c| duck-schema-load $c }
}

def "duckdb-table" [context: string]: nothing -> list<string> {
  sql complete-tables (duckdb-catalog $context)
}

# Comma-list variant for the `schema --include/--exclude` filters: re-prepend the
# already-typed tables so accepting a candidate extends the list.
def "duckdb-tables-csv" [context: string]: nothing -> list<string> {
  let prefix = (complete token $context | str replace --regex '[^,]*$' '')
  sql complete-tables (duckdb-catalog $context) | each {|t| $"($prefix)($t)" }
}

def "duckdb-column" [context: string]: nothing -> list<string> {
  # `select` names its table with --from; `update`/`delete` take it as the leading
  # positional — fall back to that so column completion works for the write verbs too.
  let tbl = (complete flag $context [--from -F] | default (sql lead-arg $context [update delete]))
  sql complete-columns (duckdb-catalog $context) $tbl
}

# Comma-list variant of `duckdb-column` for the multi-value `--group-by`/`--distinct-on`/
# `--returning` flags: re-prepend the already-typed columns so accepting a candidate
# extends the list (Nushell can't complete inside a `[...]` list literal).
def "duckdb-columns-csv" [context: string]: nothing -> list<string> {
  let prefix = (complete token $context | str replace --regex '[^,]*$' '')
  duckdb-column $context | each {|c| $"($prefix)($c)" }
}

# Completion-only distinct-value probe: a read-only SELECT (opened `--readonly` so it
# never collides with a dev session holding the file; the LIMIT bounds it — DuckDB is
# embedded, so there is no connect/timeout to bound), returning the `v` column's
# values (empty on any non-zero exit). Separate from `duck-exec`'s callers so the
# verbs are untouched; the caller wraps it in `try`.
def duck-probe [conf: record, sql: string]: nothing -> list<string> {
  let r = (duck-exec $conf $sql --readonly)
  if ($r.exit_code != 0) { return [] }
  $r.stdout | from csv --no-infer | get -o v | default []
}

# Completer for the rest slot that holds BOTH projections and `col<op>value`
# predicate tokens (`select`'s ...columns, `delete`'s ...predicates). A BARE token
# completes column names (like `duckdb-column`). An `=`/`!=` token runs a LIVE,
# bounded `SELECT DISTINCT <col>` — scoped to the sibling predicates and `--from`
# table already on the line — and offers `col<op>value` for each distinct value
# (best-effort: unreachable/slow/errored → no candidates). Comparison/LIKE/`in:`
# tokens complete nothing; a distinct value with spaces/quotes may need manual
# quoting when accepted.
def "duckdb-arg" [context: string]: nothing -> list<string> {
  let p = (sql predicate-token (complete token $context))
  if ($p == null) { return (duckdb-column $context) }
  if ($p.op not-in ["=" "!="]) or ($p.value | str starts-with "in:") { return [] }
  let table = (complete flag $context [--from -F] | default (sql lead-arg $context [update delete]))
  let conf = (complete conn-ctx $context "duckdb")
  if ($table | is-empty) or ($conf | is-empty) { return [] }
  let siblings = (sql split-args (complete positionals $context) | get predicates | where col != $p.col)
  # The probe SELECT frame (incl. LIMIT) is the driver's — mole-sql only composes the WHERE.
  let where = (sql build-where $siblings --dialect $DUCK_DIALECT)
  let q = (sql assemble [
    $"SELECT DISTINCT ($p.col) AS v FROM ($table)"
    (if ($where | is-not-empty) { $"WHERE ($where)" })
    "LIMIT 50"
  ])
  (try { duck-probe $conf $q } catch { [] }) | each {|v| $p.col + $p.op + $v }
}

# ---- SELECT clause renderers (duckdb-specific) --------------------------------

# SELECT head: `SELECT [DISTINCT | DISTINCT ON (...)] <cols>` (cols verbatim).
# DuckDB supports both plain DISTINCT and DISTINCT ON (...).
def duck-projection [columns: list<string>, distinct: bool, distinct_on: list<string>]: nothing -> string {
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
def duck-order-term [term: string]: nothing -> string {
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
def duck-order [sort_by: any]: nothing -> any {
  if ($sort_by | is-empty) { return null }
  let terms = ($sort_by | split row "," | each {|t| duck-order-term $t } | where {|t| $t | is-not-empty })
  sql join-list $terms --prefix "ORDER BY "
}

# ---- user verbs ---------------------------------------------------------------

# Run an arbitrary SQL statement against a DuckDB database file.
#
# The statement text is the positional <sql>, a saved `--file` (resolved under
# the query dir with a `.sql` suffix), or `$EDITOR` when neither is given. Cells
# come back LOSSLESS — every value is the string `duckdb` printed, uncoerced (use
# `select` when you want DB-typed rows). A statement matching the dialect danger
# regex (writes, DDL, PRAGMA, ATTACH, …) prompts for confirmation first, which
# `--yes` skips. The connection is the current duckdb one unless `--connection`
# names another; the target is a FILE PATH (--path / --database / --set, default
# :memory:).
#
# Named `raw-query`, not `run`, because `run` is a Nushell parser keyword. Reference
# invocations (leaf verb — call it as your loader exposes it, e.g. `mole-duckdb raw-query`):
#
#   mole-duckdb raw-query "SELECT 42 AS n"                                   # the current connection
#   mole-duckdb raw-query "SELECT id, email FROM users ORDER BY id" -c duckdb-local-dev
#   mole-duckdb raw-query --file reports/active-users -c duckdb-local-dev    # <querydir>/reports/active-users.sql
#   mole query show reports/active-users.sql | mole-duckdb raw-query -c duckdb-local-dev  # query text piped via stdin
#   mole-duckdb raw-query "CREATE TABLE t (id int)" -c duckdb-local-dev --yes   # skip the danger prompt
@category mole-duckdb
export def "raw-query" [
  sql?: string                                     # SQL statement (else --file, else stdin, else $EDITOR)
  --file(-f): string@"complete queryfile"          # saved query file (relative to the query dir)
  --connection(-c): string@complete-connection   # named connection (default: current)
  --path(-p): string                               # override the database file path (or :memory:)
  --database(-d): string                           # override the database file path (alias of --path)
  --set: record = {}                               # override any other connection field(s)
  --yes(-y)                                         # skip the dangerous-query prompt
] {
  let conf = (duck-conf $connection $path $database $set)
  let text = ($in | query resolve $sql --file $file --suffix ".sql")
  if (query is-dangerous $text (duck-dangerous)) and (not (query confirm "This query may modify data. Run it?" --yes=$yes)) {
    return
  }
  duck-rows $conf $text
}

# Compose and run a single-table DuckDB SELECT, returning DB-typed rows.
#
# Clause bodies (columns, --where, --having, --sort-by terms) are passed to
# duckdb VERBATIM — expressions like `count(*)`, `lower(x)` work; quote reserved
# identifiers yourself. There is NO join support: the query always reads the
# single `--from` table.
#
# A positional token shaped `col<op>value` (`status=active`, `age>=30`,
# `name~%acme%`, `role=in:admin,ops`, `deleted=null`) is composed into the WHERE
# clause — AND-joined, and AND-combined with any raw `--where` — with its column
# name tab-completing. Operators are `= != > >= < <=`, `~`/`!~` (LIKE / NOT LIKE),
# and the `=null` / `=in:` forms; the value is quoted by shape (numbers/bools bare,
# else a string literal). Bare tokens stay projected columns. Anything the grammar
# can't express (an expression RHS, `OR`, a sub-select) goes in `--where`.
#
# Only the `--from` table's cached columns are DB-typed;
# computed/aliased columns come back as lossless strings (use --raw to skip
# typing entirely). --dry-run returns a {connection, query} record without running (secrets dropped). Connection/target
# overridable via --connection + --path/--database/--set. DuckDB has no row
# locking, so there are no --lock flags.
@category mole-duckdb
@example "every column of a table" {
  mole-duckdb select --from users --dry-run | get query
} --result "SELECT * FROM users"
@example "project, filter, order and limit" {
  mole-duckdb select id email --from users --where "age > 30" --sort-by "age desc" --limit 5 --dry-run | get query
} --result "SELECT id, email FROM users WHERE age > 30 ORDER BY age DESC LIMIT 5"
@example "DISTINCT" {
  mole-duckdb select status --distinct --from orders --dry-run | get query
} --result "SELECT DISTINCT status FROM orders"
@example "DISTINCT ON — first row per user" {
  mole-duckdb select user_id status --distinct-on user_id --from orders --sort-by "user_id, id desc" --dry-run | get query
} --result "SELECT DISTINCT ON (user_id) user_id, status FROM orders ORDER BY user_id, id DESC"
@example "aggregate with GROUP BY and HAVING" {
  mole-duckdb select user_id "count(*) AS n" --from orders --group-by user_id --having "count(*) > 1" --sort-by "n desc" --dry-run | get query
} --result "SELECT user_id, count(*) AS n FROM orders GROUP BY user_id HAVING count(*) > 1 ORDER BY n DESC"
@example "ORDER BY ... NULLS LAST" {
  mole-duckdb select email age --from users --sort-by "age desc nulls last" --dry-run | get query
} --result "SELECT email, age FROM users ORDER BY age DESC NULLS LAST"
@example "pagination with LIMIT + OFFSET" {
  mole-duckdb select --from users --sort-by id --limit 2 --offset 2 --dry-run | get query
} --result "SELECT * FROM users ORDER BY id LIMIT 2 OFFSET 2"
@example "predicate tokens compose the WHERE clause (columns complete)" {
  mole-duckdb select id email --from users status=active age>=30 --dry-run | get query
} --result "SELECT id, email FROM users WHERE status = 'active' AND age >= 30"
@example "IN, LIKE and NULL predicate forms, AND-combined with a raw --where" {
  mole-duckdb select --from users role=in:admin,ops name~%acme% deleted=null --where "score > 0" --dry-run | get query
} --result "SELECT * FROM users WHERE role IN ('admin', 'ops') AND name LIKE '%acme%' AND deleted IS NULL AND (score > 0)"
@example "run for real — base-table columns come back DB-typed" {
  mole-duckdb select email is_active balance --from users --sort-by id -c duckdb-local-dev
}
export def "select" [
  ...columns: string@"duckdb-arg"                  # projected columns, or `col<op>value` predicate tokens (default: *)
  --from(-F): string@"duckdb-table"                # source table, single table only (an alias is allowed: "users u")
  --where(-w): string                              # raw WHERE predicate, AND-combined with any col<op>value tokens
  --group-by(-g): string@"duckdb-columns-csv"      # GROUP BY keys, comma-separated
  --having: string                                 # HAVING predicate (without the keyword)
  --sort-by(-s): string                            # ORDER BY terms, comma-separated: "col [asc|desc] [nulls first|last]"
  --limit(-l): int                                 # LIMIT N
  --offset(-o): int                                # OFFSET N
  --distinct                                       # SELECT DISTINCT
  --distinct-on: string@"duckdb-columns-csv"       # SELECT DISTINCT ON (...), comma-separated
  --connection(-c): string@complete-connection   # named connection (default: current)
  --path(-p): string                               # database file path (or :memory:)
  --database(-d): string                           # database file path (alias of --path)
  --set: record = {}
  --raw(-R)                                         # skip type coercion (all strings)
  --dry-run(-n)                                    # return a {connection, query} record instead of running
  --yes(-y)                                         # skip the dangerous-query prompt
] {
  # Multi-value flags arrive as ONE comma-joined string (Nushell can't complete inside a
  # `[...]` literal); decode to the list the clause renderers want, shadowing the params.
  let group_by = (sql csv-split $group_by)
  let distinct_on = (sql csv-split $distinct_on)
  if $distinct and ($distinct_on | is-not-empty) {
    error make {msg: "select: --distinct and --distinct-on are mutually exclusive"}
  }
  if ($from | is-empty) { error make {msg: "select: --from <table> is required"} }
  # Split the rest slot: bare tokens are projections, `col<op>value` tokens are WHERE
  # predicates, AND-combined with the raw --where.
  let parts = (sql split-args $columns)
  let where_sql = (sql build-where $parts.predicates --raw ($where | default "") --dialect $DUCK_DIALECT)
  let text = (sql assemble [
    (duck-projection $parts.projections $distinct ($distinct_on | default []))
    $"FROM ($from)"
    (if ($where_sql | is-not-empty) { $"WHERE ($where_sql)" })
    (sql join-list ($group_by | default []) --prefix "GROUP BY ")
    (if ($having | is-not-empty) { $"HAVING ($having)" })
    (duck-order $sort_by)
    (if $limit != null { $"LIMIT ($limit)" })
    (if $offset != null { $"OFFSET ($offset)" })
  ])
  let conf = (duck-conf $connection $path $database $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (query is-dangerous $text (duck-dangerous)) and (not (query confirm "This query may modify data. Run it?" --yes=$yes)) {
    return
  }
  let rows = (duck-rows $conf $text)
  if $raw { return $rows }
  $rows
  | sql normalize-nulls $DUCK_NULLS
  | sql apply-types (sql columns-for (duck-schema-load $conf) (sql base-table $from)) {|c| duck-type $c }
}

# Compose and run a single-table DuckDB UPDATE.
#
# Reads like the statement: `update <table> <assignment>...`. The table is the
# leading positional (completing table names); the SET assignments follow as
# positionals — each a verbatim `"col = expr"`, so expressions (`hits = hits + 1`)
# all work; you quote identifiers and string literals yourself, and their column
# names complete against the table. `--where` is the same verbatim predicate as
# `select`; `--returning` names columns to hand back for the changed rows (DuckDB
# RETURNING), typed exactly like a `select` result. There is NO join support — the
# target is the single table; reach for `raw-query` for `UPDATE ... FROM`.
#
# UPDATE always writes, so it prompts before running (skip with `--yes`) and
# REFUSES to touch every row unless you pass `--all`. `--dry-run` returns a
# `{connection, query}` record without running. Connection/target overridable via
# `--connection` + `--path` / `--database` / `--set`.
@category mole-duckdb
@example "set a column on the matched rows" {
  mole-duckdb update users "status = 'inactive'" --where "id = 5" --dry-run | get query
} --result "UPDATE users SET status = 'inactive' WHERE id = 5"
@example "expression assignment, returning the new value" {
  mole-duckdb update users "login_count = login_count + 1" --where "id = 42" --returning id,login_count --dry-run | get query
} --result "UPDATE users SET login_count = login_count + 1 WHERE id = 42 RETURNING id, login_count"
@example "guard: an unfiltered UPDATE needs --all" {
  mole-duckdb update users "archived = true" --all --dry-run | get query
} --result "UPDATE users SET archived = true"
export def "update" [
  table: string@"duckdb-table"                     # target table (UPDATE <table>); single table, an alias is allowed: "users u"
  ...assignments: string@"duckdb-column"           # SET assignments, verbatim "col = expr" (at least one required)
  --where(-w): string                              # WHERE predicate (without the keyword)
  --returning: string@"duckdb-columns-csv"         # RETURNING columns, comma-separated (typed like a select result)
  --all                                            # allow an unfiltered UPDATE (every row) when --where is omitted
  --connection(-c): string@complete-connection   # named connection (default: current)
  --path(-p): string                               # database file path (or :memory:)
  --database(-d): string                           # database file path (alias of --path)
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
  let text = (sql build-update --table $table --set $assignments --where ($where | default "") --returning ($returning | default []))
  let conf = (duck-conf $connection $path $database $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (not (query confirm "This UPDATE will modify rows. Run it?" --yes=$yes)) { return }
  let rows = (duck-rows $conf $text)
  if $raw or ($rows | is-empty) { return $rows }
  $rows
  | sql normalize-nulls $DUCK_NULLS
  | sql apply-types (sql columns-for (duck-schema-load $conf) (sql base-table $table)) {|c| duck-type $c }
}

# Compose and run a single-table DuckDB DELETE.
#
# Reads like the statement: `delete <table> <predicate>...`. The table is the
# leading positional (completing table names); the `col<op>value` predicate tokens
# (`user_id=7`, `status=inactive`, `role=in:a,b`) are AND-joined into the WHERE
# clause, their column names completing — the same grammar as `select`. `--where`
# is the raw escape (for an expression RHS like `now()`, `OR`, a sub-select),
# AND-combined with the tokens. `--returning` names columns to hand back for the
# deleted rows (DuckDB RETURNING), typed exactly like a `select` result. There is
# NO join support — deletes from the single table; reach for `raw-query` for
# `DELETE ... USING`.
#
# DELETE always writes, so it prompts before running (skip with `--yes`) and
# REFUSES to delete every row unless you pass `--all`. `--dry-run` returns a
# `{connection, query}` record without running. Connection/target overridable as
# in `update`.
@category mole-duckdb
@example "predicate tokens build the filter (columns complete)" {
  mole-duckdb delete sessions user_id=7 --dry-run | get query
} --result "DELETE FROM sessions WHERE user_id = 7"
@example "an expression filter uses the raw --where" {
  mole-duckdb delete sessions --where "expires_at < now()" --dry-run | get query
} --result "DELETE FROM sessions WHERE expires_at < now()"
@example "delete, returning everything that was removed" {
  mole-duckdb delete sessions --where "user_id = 7" --returning "*" --dry-run | get query
} --result "DELETE FROM sessions WHERE user_id = 7 RETURNING *"
@example "guard: an unfiltered DELETE needs --all" {
  mole-duckdb delete staging_rows --all --dry-run | get query
} --result "DELETE FROM staging_rows"
export def "delete" [
  table: string@"duckdb-table"                     # target table (DELETE FROM <table>); single table, an alias is allowed: "users u"
  ...predicates: string@"duckdb-arg"               # `col<op>value` filter tokens (AND-joined): user_id=7  status=inactive  role=in:a,b
  --where(-w): string                              # raw WHERE predicate, AND-combined with any predicate tokens
  --returning: string@"duckdb-columns-csv"         # RETURNING columns, comma-separated (typed like a select result)
  --all                                            # allow an unfiltered DELETE (every row) when no filter is given
  --connection(-c): string@complete-connection   # named connection (default: current)
  --path(-p): string                               # database file path (or :memory:)
  --database(-d): string                           # database file path (alias of --path)
  --set: record = {}
  --raw(-R)                                         # raw driver output for RETURNING rows: no typing, no null-normalization
  --dry-run(-n)                                    # return a {connection, query} record instead of running
  --yes(-y)                                         # skip the confirmation prompt
] {
  let parts = (sql split-args $predicates)
  if ($parts.projections | is-not-empty) {
    error make {msg: ("delete: incomplete predicate(s): " + ($parts.projections | str join ", ") + " — use col=value, col>=value, col~pattern, col=in:a,b or col=null")}
  }
  let where_sql = (sql build-where $parts.predicates --raw ($where | default "") --dialect $DUCK_DIALECT)
  if ($where_sql | is-empty) and (not $all) {
    error make {msg: "delete: refusing to delete every row without a filter (pass --all to override)"}
  }
  let returning = (sql csv-split $returning)   # comma-joined string → list (Nushell can't complete inside `[...]`)
  let text = (sql build-delete --table $table --where ($where_sql | default "") --returning ($returning | default []))
  let conf = (duck-conf $connection $path $database $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (not (query confirm "This DELETE will remove rows. Run it?" --yes=$yes)) { return }
  let rows = (duck-rows $conf $text)
  if $raw or ($rows | is-empty) { return $rows }
  $rows
  | sql normalize-nulls $DUCK_NULLS
  | sql apply-types (sql columns-for (duck-schema-load $conf) (sql base-table $table)) {|c| duck-type $c }
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
# Connection/target overridable as in `raw-query`.
@category mole-duckdb
@example "summary — one row per table" {
  mole-duckdb schema -c duckdb-local-dev
}
@example "detail for one table (its columns + constraints)" {
  mole-duckdb schema --table users -c duckdb-local-dev
}
@example "search names and comments for 'balance'" {
  mole-duckdb schema --find balance -c duckdb-local-dev
}
@example "rebuild the cache from the live database first" {
  mole-duckdb schema --refresh -c duckdb-local-dev
}
@example "the raw cache record, including meta" {
  mole-duckdb schema --full -c duckdb-local-dev
}
@example "render only the core tables as a Mermaid ER diagram" {
  mole-duckdb schema --full --include "users,orders,order_items" -c duckdb-local-dev | mole-mermaid er-schema
}
@example "dump everything except staging tables" {
  mole-duckdb schema --full --exclude "stg_*,tmp_*" -c duckdb-local-dev
}
export def "schema" [
  --connection(-c): string@complete-connection   # named connection (default: current)
  --table(-t): string@"duckdb-table"               # detail view for one table
  --find: string                                   # find tables/columns by name or comment (case-insensitive)
  --refresh(-r)                                    # rebuild the cache before reading
  --full                                           # return the full cache record
  --include: string@"duckdb-tables-csv"            # keep ONLY these tables — comma-sep names/globs (mutually exclusive with --exclude)
  --exclude: string@"duckdb-tables-csv"            # drop these tables — comma-sep names/globs (mutually exclusive with --include)
  --path(-p): string                               # override the database file path (or :memory:)
  --database(-d): string                           # override the database file path (alias of --path)
  --set: record = {}                               # override any other connection field(s)
] {
  if ($include | is-not-empty) and ($exclude | is-not-empty) {
    error make {msg: "schema: --include and --exclude are mutually exclusive"}
  }
  let conf = (duck-conf $connection $path $database $set)
  let data = (sql schema-filter (duck-schema-load $conf --refresh=$refresh) --include (sql csv-split $include) --exclude (sql csv-split $exclude))
  if $full { return $data }
  if ($find | is-not-empty) {
    sql schema-find $data $find
  } else if ($table | is-not-empty) {
    sql schema-detail $data $table
  } else {
    sql schema-tables $data
  }
}

# Make a duckdb connection the current one for this driver.
#
# Records the choice in `$env.MOLE_CURRENT.duckdb`, so later `raw-query` / `select` /
# `schema` calls can omit `--connection`. Validates that `name` exists and is
# actually a duckdb connection (errors otherwise). Being `--env`, the change
# persists in the caller's environment.
@category mole-duckdb
@example "make the local dev database current" {
  mole-duckdb set-connection duckdb-local-dev
}
export def --env "set-connection" [
  name: string@complete-connection   # a duckdb connection name (from the connections file)
]: nothing -> nothing {
  conn set-current duckdb $name | ignore
}
