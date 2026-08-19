# mole-trino — Trino driver plugin.
#
# A PLUGIN (data source): supports the trino technology, registers itself as a
# driver, and exposes the user verbs `raw-query` / `select` / `schema`. It DEPENDS on:
#   - mole core plumbing        (`use mole/lib/*.nu`)
#   - the generic mole-sql pure LIBRARY (`use mole-sql/sql.nu`)
# The mole-sql library must be reachable via `NU_LIB_DIRS`.
#
# LAYERING: everything driver-specific (how to invoke the `trino` CLI, the
# introspection SQL, the type map, the danger regex) and all orchestration
# (resolve → exec → check → parse → cache → type) lives HERE. The library only
# ever receives data and closures. This is a sibling of mole-psql / mole-mysql,
# differing only in these private dialect pieces:
#   - a SERVER-based CLI (`--server host:port --catalog --schema`, no password),
#   - CSV_HEADER output parsed losslessly with `from csv`,
#   - a Trino type map whose parametrized types (decimal(p,s), timestamp(3), …)
#     are matched on a PREFIX,
#   - information_schema scoped to the current catalog/schema, and NO constraint
#     metadata (the constraints query returns zero rows).
# Trino connections carry two extra fields — `catalog` and `schema` — surfaced as
# `--catalog`/`--schema` overrides on every verb. Trino has no row locking, so
# unlike the RDBMS siblings there are no `--lock*` flags.

use mole/lib/conn.nu

# Driver-scoped connection completer: only THIS driver (trino), never other drivers.
def "complete-connection" []: nothing -> list<string> { conn names "trino" }
use mole/lib/cache.nu
use mole/lib/query.nu
use mole/lib/complete.nu
use mole-sql/sql.nu

export-env {
  conn register "trino"
}

# ---- dialect specifics (trino) ------------------------------------------------

# How Trino's CSV_HEADER output renders a SQL NULL: an empty field. Injected into
# the mole-sql normalizers so the pure library carries no knowledge of NULL
# spelling.
const TRINO_NULLS = [""]

# The mole-sql predicate-rendering dialect spec. Trino string literals are ANSI: `\`
# is literal, only `''` doubles a quote — so no backslash escaping.
const TRINO_DIALECT = {backslash_escapes: false}

# The dialect's WHERE-operator vocabulary: the ANSI base (`~`/`!~` = universal LIKE)
# EXTENDED with Trino's own operators, each rendered natively with a per-dialect note:
# `=~`/`!=~`→regex via the `regexp_like()` function, `<=>`→null-safe equality
# (`IS NOT DISTINCT FROM`). Trino has no symbolic ILIKE, so case-insensitive matching
# stays in `raw-query`. Injected through the same call sites as the other drivers.
def "trino-ops" []: nothing -> list {
  sql ansi-ops
  | append {token: "=~",  desc: "regex match (regexp_like)",   render: {|c, v, lit| sql render-func "regexp_like" $c $v $lit }}
  | append {token: "!=~", desc: "not regex (NOT regexp_like)", render: {|c, v, lit| "NOT " + (sql render-func "regexp_like" $c $v $lit) }}
  | append {token: "<=>", desc: "null-safe = (IS NOT DISTINCT FROM)", render: {|c, v, lit| sql render-nullsafe "IS NOT DISTINCT FROM" $c $v $lit }}
}

# Statements that warrant a confirmation prompt before running. Trino writes/DDL
# plus session-mutating statements (USE, SET SESSION, CALL, GRANT, …).
def trino-dangerous []: nothing -> string {
  '(?i)\b(insert|update|delete|merge|truncate|drop|create|alter|rename|comment|grant|revoke|deny|call|use|set\s+session|reset\s+session|set\s+role|prepare|deallocate|execute|start\s+transaction|commit|rollback|analyze)\b'
}

# Run one SQL statement, returning a `complete` record. Trino is server-based:
# address via --server host:port, identity via --user (the demo has no password),
# default namespace via --catalog/--schema. CSV_HEADER emits a header row plus
# quoted CSV, so `from csv` recovers the column names and parses losslessly.
def trino-exec [conf: record, sql: string]: nothing -> record {
  let server = $"($conf.host):($conf | get -o port | default 8080)"
  (^trino
    --server $server
    --user ($conf | get -o user | default "admin")
    --catalog $conf.catalog
    --schema $conf.schema
    --output-format CSV_HEADER
    --execute $sql
  ) | complete
}

# Exec + check + lossless parse (every cell stays a string).
def trino-rows [conf: record, sql: string]: nothing -> any {
  trino-exec $conf $sql | query check | from csv --no-infer
}

# data_type → cell-converter closure (or null to leave the column as-is).
#
# Trino renders parametrized types WITH their parameters in information_schema
# (decimal(10,2), timestamp(3), timestamp(3) with time zone, varchar(255), …), so
# we match on a PREFIX. Timestamps carrying a time zone still `into datetime`.
def trino-type [col: record]: nothing -> any {
  let dt = ($col | get -o data_type | default "" | into string | str lowercase | str trim)
  if $dt == "boolean" { return (sql null-or {|x| ($x | str lowercase) in ["true" "t" "yes" "1"] }) }
  if $dt in ["tinyint" "smallint" "integer" "bigint"] { return (sql null-or {|x| $x | into int }) }
  if $dt == "real" or $dt == "double" or ($dt | str starts-with "decimal") {
    return (sql null-or {|x| $x | into float })
  }
  if $dt == "date" or ($dt | str starts-with "timestamp") {
    return (sql null-or {|x| $x | into datetime })
  }
  if $dt == "json" { return (sql null-or {|x| $x | from json }) }
  null
}

# Friendly column type. Trino's information_schema data_type already carries the
# parameters (decimal(10,2), varchar(255), timestamp(3)), so use it verbatim.
def trino-display-type [c: record]: nothing -> string {
  $c.data_type | into string
}

# Tables in the current catalog/schema. Trino has no cheap row estimate, so
# row_estimate is a literal 0. AS-aliased to the common `tables` names.
def trino-tables-sql []: nothing -> string {
  r#'
    SELECT
      table_schema AS "schema",
      table_name AS "name",
      table_type AS "type",
      CAST(NULL AS varchar) AS "comment",
      0 AS "row_estimate"
    FROM information_schema.tables
    WHERE table_schema = current_schema
    ORDER BY table_schema, table_name
  '#
}

# Columns in the current catalog/schema. Trino has no per-column comment in
# information_schema.columns, so comment is NULL. AS-aliased to the common
# `columns` names; `data_type` carries any type parameters (see trino-type).
def trino-columns-sql []: nothing -> string {
  r#'
    SELECT
      table_schema AS "schema",
      table_name AS "table",
      column_name AS "name",
      ordinal_position AS "position",
      data_type AS "data_type",
      data_type AS "udt_name",
      is_nullable AS "is_nullable",
      column_default AS "default",
      CAST(NULL AS bigint) AS "char_max_length",
      CAST(NULL AS bigint) AS "numeric_precision",
      CAST(NULL AS bigint) AS "numeric_scale",
      comment AS "comment"
    FROM information_schema.columns
    WHERE table_schema = current_schema
    ORDER BY table_schema, table_name, ordinal_position
  '#
}

# Trino exposes NO primary/foreign/unique-key metadata, so this yields zero rows
# with exactly the common `constraints` shape (WHERE false). `sql schema-body`
# tolerates an empty constraints section.
def trino-constraints-sql []: nothing -> string {
  r#'
    SELECT
      CAST(NULL AS varchar) AS "schema",
      CAST(NULL AS varchar) AS "table",
      CAST(NULL AS varchar) AS "name",
      CAST(NULL AS varchar) AS "type",
      CAST(NULL AS varchar) AS "columns",
      CAST(NULL AS varchar) AS "ref_schema",
      CAST(NULL AS varchar) AS "ref_table",
      CAST(NULL AS varchar) AS "ref_columns"
    WHERE false
  '#
}

# ---- orchestration ------------------------------------------------------------

# Load the schema cache for a connection, rebuilding when --refresh or stale.
# Keyed by <name>__<catalog>.<schema> since a Trino server hosts many of each.
def trino-schema-load [conf: record, --refresh]: nothing -> record {
  let cat = ($conf | get -o catalog | default "_")
  let sch = ($conf | get -o schema | default "_")
  let file = (cache path "trino" $"($conf.name)__($cat).($sch)")
  if $refresh or (cache stale $file 1day) {
    let secs = [
        {k: "tables"      q: (trino-tables-sql)}
        {k: "columns"     q: (trino-columns-sql)}
        {k: "constraints" q: (trino-constraints-sql)}
      ]
      | par-each {|s| {key: $s.k, rows: (trino-rows $conf $s.q)} }
      | reduce --fold {} {|it, acc| $acc | upsert $it.key $it.rows }
    let body = (sql schema-body $secs.tables $secs.columns $secs.constraints {|c| trino-display-type $c } $TRINO_NULLS)
    let data = ({meta: {connection: $conf.name, catalog: $cat, schema: $sch, driver: "trino", refreshed_at: (date now)}} | merge $body)
    $data | cache write $file
    return $data
  }
  cache read $file
}

# The standard override record: named flags win over the resolved connection, and
# --set wins over the named flags (for arbitrary/driver-specific fields). Trino
# adds `catalog`/`schema` to the psql/mysql field set.
def trino-conf [
  connection: any, host: any, port: any,
  user: any, catalog: any, schema: any, set: record
]: nothing -> record {
  conn with trino $connection ({
    host: $host, port: $port,
    user: $user, catalog: $catalog, schema: $schema
  } | merge $set)
}

# ---- completers (cache-backed; build the schema on a cache miss) --------------
# These call trino-schema-load, so a first completion against a not-yet-cached (or
# day-stale) connection introspects the live cluster once, then serves from cache.

def trino-catalog [context: string]: nothing -> record {
  complete catalog-ctx $context trino --get {|c| trino-schema-load $c }
}

def "trino-table" [context: string]: nothing -> list<string> {
  sql complete-tables (trino-catalog $context)
}

# Comma-list variant for the `schema --include/--exclude` filters: re-prepend the
# already-typed tables so accepting a candidate extends the list.
def "trino-tables-csv" [context: string]: nothing -> list<string> {
  let prefix = (complete token $context | str replace --regex '[^,]*$' '')
  sql complete-tables (trino-catalog $context) | each {|t| $"($prefix)($t)" }
}

def "trino-column" [context: string]: nothing -> list<string> {
  # `select` names its table with --from; `update`/`delete` take it as the leading
  # positional — fall back to that so column completion works for the write verbs too.
  let tbl = (complete flag $context [--from -F] | default (sql lead-arg $context [update delete]))
  sql complete-columns (trino-catalog $context) $tbl
}

# Comma-list variant of `trino-column` for the multi-value column flags (`stats`'
# `--by`/`--sum`/`--avg`/…): re-prepend the already-typed columns so accepting a
# candidate extends the list (Nushell can't complete inside a `[...]` list literal).
def "trino-columns-csv" [context: string]: nothing -> list<string> {
  let prefix = (complete token $context | str replace --regex '[^,]*$' '')
  trino-column $context | each {|c| $"($prefix)($c)" }
}

# `select`'s `--sort-by` completer: the source columns as `col[:desc]` sort tokens.
def "trino-sort" [context: string]: nothing -> list<string> { complete sort-csv $context (trino-column $context) }

# Completion-only bounded/quiet distinct-value probe: a read-only SELECT run with a
# short `--client-request-timeout` (the LIMIT bounds the result), returning the `v`
# column's values (empty on any non-zero exit). Separate from `trino-exec` so the
# verbs are untouched; the caller wraps it in `try`.
def trino-probe [conf: record, sql: string]: nothing -> list<string> {
  let server = $"($conf.host):($conf | get -o port | default 8080)"
  let r = (^trino
    --server $server
    --user ($conf | get -o user | default "admin")
    --catalog ($conf | get -o catalog)
    --schema ($conf | get -o schema)
    --client-request-timeout 3s
    --output-format CSV_HEADER
    --execute $sql
  | complete)
  if ($r.exit_code != 0) { return [] }
  $r.stdout | from csv --no-infer | get -o v | default []
}

# `--where` completer, csv-aware: `--where` holds a comma-list of `col<op>value` tokens;
# this completes the LAST segment and re-prepends the earlier ones. Three stages: a
# partial segment → column NAMES; a COMPLETE column → the dialect OPERATORS (`col=`,
# … via `op-completions`, so you never type `=` by hand); an `=`/`!=` segment → a LIVE,
# bounded `SELECT DISTINCT <col>` scoped to the committed sibling predicates + the
# `--from`/leading table, offering `col<op>value` per distinct value (best-effort). A
# comparison/LIKE/`in:` segment, or a bare segment right after an open `in:` list,
# completes nothing further.
def "trino-where" [context: string]: nothing -> list<any> {
  let ops = (trino-ops)
  let tok = (complete token $context)
  let prefix = ($tok | str replace --regex '[^,]*$' '')       # everything up to & incl the last comma
  let seg = ($tok | split row "," | last | default "")         # the segment being typed
  let committed = ($prefix | str trim --char ",")
  let pref_preds = (sql parse-where $committed --ops $ops)
  let p = (sql predicate-token $seg --ops $ops)
  # mid open-in:-list — a bare segment after an in:-valued predicate ⇒ don't offer columns
  if ($p == null) and ($pref_preds != null) and ($pref_preds | is-not-empty) and (($pref_preds | last | get value) | str starts-with "in:") {
    return []
  }
  if ($p == null) {
    let cols = (trino-column $context)
    if ($seg in $cols) {
      let longer = ($cols | where {|c| $c != $seg and ($c | str starts-with $seg) } | each {|c| {value: ($prefix + $c), description: "column"} })
      return (((sql op-completions $seg $ops) | each {|r| {value: ($prefix + $r.value), description: $r.description} }) ++ $longer)
    }
    return ($cols | each {|c| $prefix + $c })
  }
  if ($p.op not-in ["=" "!="]) or ($p.value | str starts-with "in:") { return [] }
  let table = (complete flag $context [--from -F] | default (sql lead-arg $context [update delete]))
  let conf = (complete conn-ctx $context "trino")
  if ($table | is-empty) or ($conf | is-empty) { return [] }
  let siblings = (if ($pref_preds == null) { [] } else { $pref_preds | where col != $p.col })
  let where = (sql render-where $siblings --dialect $TRINO_DIALECT --ops $ops)
  let q = (sql assemble [
    $"SELECT DISTINCT ($p.col) AS v FROM ($table)"
    (if ($where | is-not-empty) { $"WHERE ($where)" })
    "LIMIT 50"
  ])
  (try { trino-probe $conf $q } catch { [] }) | each {|v| $prefix + $p.col + $p.op + $v }
}

# ---- SELECT clause renderers (trino-specific) ---------------------------------

# SELECT head: `SELECT [DISTINCT] <cols>` (cols verbatim). Trino has no DISTINCT ON.
def trino-projection [columns: list<string>, distinct: bool]: nothing -> string {
  let cols = if ($columns | is-empty) { "*" } else { $columns | str join ", " }
  $"SELECT (if $distinct { 'DISTINCT ' } else { '' })($cols)"
}

# ---- user verbs ---------------------------------------------------------------

# Run an arbitrary SQL statement against a Trino connection.
#
# The statement text is the positional <sql>, a saved `--file` (resolved under
# the query dir with a `.sql` suffix), or `$EDITOR` when neither is given. Cells
# come back LOSSLESS — every value is the string the `trino` CLI printed in its
# CSV_HEADER output, uncoerced (use `select` when you want DB-typed rows). A
# statement matching the dialect danger regex (writes, DDL, session mutations, …)
# prompts for confirmation first, which `--yes` skips. The connection is the
# current trino one unless `--connection` names another; per-field flags,
# `--catalog`/`--schema`, and `--set` override individual fields.
#
# Named `raw-query`, not `run`, because `run` is a Nushell parser keyword. Reference
# invocations (leaf verb — call it as your loader exposes it, e.g. `mole-trino raw-query`):
#
#   mole-trino raw-query "SELECT 1 AS n"                                    # the current connection
#   mole-trino raw-query "SELECT custkey, name FROM customer LIMIT 5" -c trino-local-dev
#   mole-trino raw-query --file reports/top-customers -c trino-local-dev    # <querydir>/reports/top-customers.sql
#   mole query show reports/top-customers.sql | mole-trino raw-query -c trino-local-dev  # query text piped via stdin
#   mole-trino raw-query "SELECT * FROM lineitem" -c trino-local-dev --catalog tpch --schema sf1
@category mole-trino
export def "raw-query" [
  sql?: string                                     # SQL statement (else --file, else stdin, else $EDITOR)
  --file(-f): string@"complete queryfile"          # saved query file (relative to the query dir)
  --connection(-c): string@complete-connection   # named connection (default: current)
  --host(-h): string                               # override host
  --port(-p): int                                  # override port
  --user(-u): string                               # override user
  --catalog: string                                # override catalog (Trino-specific)
  --schema: string                                 # override schema (Trino-specific)
  --set: record = {}                               # override any other connection field(s)
  --yes(-y)                                         # skip the dangerous-query prompt
] {
  let conf = (trino-conf $connection $host $port $user $catalog $schema $set)
  let text = ($in | query resolve $sql --file $file --suffix ".sql")
  if (query is-dangerous $text (trino-dangerous)) and (not (query confirm "This query may modify data. Run it?" --yes=$yes)) {
    return
  }
  trino-rows $conf $text
}

# Compose and run a single-table Trino SELECT, returning DB-typed ROWS.
#
# Clause bodies (columns, --where, --sort-by terms) are passed to the
# `trino` CLI VERBATIM — expressions like `lower(x)` work; quote
# reserved identifiers yourself. There is NO join support: the query always reads
# the single `--from` table. This verb projects ROWS only — grouped aggregation
# (GROUP BY / HAVING) is `stats`.
#
# The projected columns are the rest slot (`custkey name`, `lower(x)`; commas optional,
# default `*`), passed to the `trino` CLI VERBATIM. The WHERE clause is `--where`,
# DUAL-MODE: a comma-separated `col<op>value` token-list (`status=active,age>=30`,
# `name~%acme%`, `role=in:admin,ops`, `deleted=null`) whose columns AND operators
# tab-complete; or — when it doesn't parse as tokens — raw SQL passed through verbatim
# (an `OR`, a sub-select, `now()`, spaced operators). Token operators are `= != > >= < <=`,
# `~`/`!~` (LIKE / NOT LIKE), and the `=null` / `=in:` forms; the value is quoted by
# shape (numbers/bools bare, else a string literal). `--sort-by` orders by `col[:desc]`
# tokens (a bare column is ASC); `NULLS FIRST|LAST` and expression ordering are a
# `raw-query`.
#
# Only the `--from` table's cached columns are
# DB-typed; computed/aliased columns come back as lossless strings (use --raw to
# skip typing entirely). --dry-run returns a {connection, query} record without running (secrets dropped). Connection is
# overridable via --connection + per-field flags / --catalog / --schema / --set.
# Trino has no row locking, so there are no `--lock*` flags.
@category mole-trino
@example "every column of a table" {
  mole-trino select --from customer --dry-run | get query
} --result "SELECT * FROM customer"
@example "project, filter, order and limit" {
  mole-trino select custkey name acctbal --from customer --where "acctbal > 5000" --sort-by acctbal:desc --limit 5 --dry-run | get query
} --result "SELECT custkey, name, acctbal FROM customer WHERE acctbal > 5000 ORDER BY acctbal DESC LIMIT 5"
@example "DISTINCT (Trino has no DISTINCT ON)" {
  mole-trino select mktsegment --distinct --from customer --dry-run | get query
} --result "SELECT DISTINCT mktsegment FROM customer"
@example "pagination with LIMIT + OFFSET" {
  mole-trino select --from customer --sort-by custkey --limit 5 --offset 10 --dry-run | get query
} --result "SELECT * FROM customer ORDER BY custkey LIMIT 5 OFFSET 10"
@example "a --where token-list composes the WHERE clause (columns + operators complete)" {
  mole-trino select custkey name --from customer --where mktsegment=BUILDING,acctbal>=5000 --dry-run | get query
} --result "SELECT custkey, name FROM customer WHERE mktsegment = 'BUILDING' AND acctbal >= 5000"
@example "--where falls back to raw SQL when it isn't a token-list" {
  mole-trino select --from customer --where "acctbal > 0 AND mktsegment <> 'AUTOMOBILE'" --dry-run | get query
} --result "SELECT * FROM customer WHERE acctbal > 0 AND mktsegment <> 'AUTOMOBILE'"
@example "IN, LIKE and NULL predicate forms in one --where token-list" {
  mole-trino select --from customer --where mktsegment=in:BUILDING,MACHINERY,name~%Corp%,phone=null --dry-run | get query
} --result "SELECT * FROM customer WHERE mktsegment IN ('BUILDING', 'MACHINERY') AND name LIKE '%Corp%' AND phone IS NULL"
@example "run for real — choose catalog/schema explicitly (tpch.tiny)" {
  mole-trino select custkey name acctbal --from customer --catalog tpch --schema tiny -c trino-local-dev
}
export def "select" [
  ...columns: string@"trino-column"                # projected columns (default: *); commas are optional and trimmed
  --from(-F): string@"trino-table"                 # source table, single table only (an alias is allowed: "customer c")
  --where(-w): string@"trino-where"                # WHERE: col<op>value token-list (comma-sep, completable) OR raw SQL
  --sort-by(-s): string@"trino-sort"               # ORDER BY terms: col[:desc], comma-separated
  --limit(-l): int                                 # LIMIT N
  --offset(-o): int                                # OFFSET N
  --distinct                                       # SELECT DISTINCT
  --connection(-c): string@complete-connection   # named connection (default: current)
  --host(-h): string
  --port(-p): int
  --user(-u): string
  --catalog: string                                # override catalog (Trino-specific)
  --schema: string                                 # override schema (Trino-specific)
  --set: record = {}
  --raw(-R)                                         # skip type coercion (all strings)
  --dry-run(-n)                                    # return a {connection, query} record instead of running
  --yes(-y)                                         # skip the dangerous-query prompt
] {
  if ($from | is-empty) { error make {msg: "select: --from <table> is required"} }
  # The rest slot is projection-only now (commas optional); WHERE lives in --where,
  # dual-mode: a col<op>value token-list, or raw SQL when it doesn't parse as tokens.
  let cols = ($columns | each {|c| $c | str trim --char "," } | where {|c| $c | is-not-empty })
  let where_sql = (sql build-where ($where | default "") --dialect $TRINO_DIALECT --ops (trino-ops))
  let text = (sql assemble [
    (trino-projection $cols $distinct)
    $"FROM ($from)"
    (if ($where_sql | is-not-empty) { $"WHERE ($where_sql)" })
    (sql build-order (sql csv-split $sort_by))
    (if $limit != null { $"LIMIT ($limit)" })
    (if $offset != null { $"OFFSET ($offset)" })
  ])
  let conf = (trino-conf $connection $host $port $user $catalog $schema $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (query is-dangerous $text (trino-dangerous)) and (not (query confirm "This query may modify data. Run it?" --yes=$yes)) {
    return
  }
  let rows = (trino-rows $conf $text)
  if $raw { return $rows }
  $rows
  | sql normalize-nulls $TRINO_NULLS
  | sql apply-types (sql columns-for (trino-schema-load $conf) (sql base-table $from)) {|c| trino-type $c }
}

# Compose and run a single-table Trino UPDATE.
#
# Reads like the statement: `update <table> <assignment>...`. The table is the
# leading positional (completing table names); the SET assignments follow as
# positionals — each a verbatim `"col = expr"`, so expressions work; you quote
# identifiers and string literals yourself, and their column names complete against
# the table. `--where` is the same dual-mode `col<op>value` token-list-or-raw-SQL
# predicate as `select`. Trino UPDATE is connector-dependent and has no RETURNING,
# no ORDER BY/LIMIT and no join support — reach for `raw-query` for anything more.
#
# UPDATE always writes, so it prompts before running (skip with `--yes`) and
# REFUSES to touch every row unless you pass `--all`. `--dry-run` returns a
# `{connection, query}` record without running. Connection overridable via
# `--connection` + per-field flags / `--catalog` / `--schema` / `--set`.
@category mole-trino
@example "set a column on the matched rows" {
  mole-trino update users "status = 'inactive'" --where "id = 5" --dry-run | get query
} --result "UPDATE users SET status = 'inactive' WHERE id = 5"
@example "several assignments at once" {
  mole-trino update t "a = 1" "b = 2" --where "id = 5" --dry-run | get query
} --result "UPDATE t SET a = 1, b = 2 WHERE id = 5"
@example "guard: an unfiltered UPDATE needs --all" {
  mole-trino update users "archived = true" --all --dry-run | get query
} --result "UPDATE users SET archived = true"
export def "update" [
  table: string@"trino-table"                      # target table (UPDATE <table>); single table, an alias is allowed: "customer c"
  ...assignments: string@"trino-column"            # SET assignments, verbatim "col = expr" (at least one required)
  --where(-w): string@"trino-where"                # WHERE: col<op>value token-list (comma-sep, completable) OR raw SQL
  --all                                            # allow an unfiltered UPDATE (every row) when --where is omitted
  --connection(-c): string@complete-connection   # named connection (default: current)
  --host(-h): string
  --port(-p): int
  --user(-u): string
  --catalog: string                                # override catalog (Trino-specific)
  --schema: string                                 # override schema (Trino-specific)
  --set: record = {}
  --dry-run(-n)                                    # return a {connection, query} record instead of running
  --yes(-y)                                         # skip the confirmation prompt
] {
  if ($assignments | is-empty) { error make {msg: "update: at least one SET assignment is required, e.g. update customer \"status = 'active'\""} }
  if ($where | is-empty) and (not $all) {
    error make {msg: "update: refusing to update every row without --where (pass --all to override)"}
  }
  # --where is dual-mode: a col<op>value token-list, or raw SQL when it doesn't parse.
  let where_sql = (sql build-where ($where | default "") --dialect $TRINO_DIALECT --ops (trino-ops))
  let text = (sql build-update --table $table --set $assignments --where ($where_sql | default ""))
  let conf = (trino-conf $connection $host $port $user $catalog $schema $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (not (query confirm "This UPDATE will modify rows. Run it?" --yes=$yes)) { return }
  trino-rows $conf $text
}

# Compose and run a single-table Trino DELETE.
#
# Reads like the statement: `delete <table> --where <predicate>`. The table is the
# leading positional (completing table names); `--where` is DUAL-MODE — a comma-
# separated `col<op>value` token-list (`user_id=7`, `status=inactive`, `role=in:a,b`,
# `deleted=null`) whose columns and operators complete, or raw SQL (an `OR`, `now()`,
# a sub-select) when it doesn't parse — the same grammar as `select`. Trino DELETE is
# connector-dependent and has no RETURNING, no ORDER BY/LIMIT and no join support —
# reach for `raw-query` for anything more.
#
# DELETE always writes, so it prompts before running (skip with `--yes`) and
# REFUSES to delete every row unless you pass `--all`. `--dry-run` returns a
# `{connection, query}` record without running. Connection overridable as in
# `update`.
@category mole-trino
@example "a --where token-list builds the filter (columns + operators complete)" {
  mole-trino delete sessions --where user_id=7 --dry-run | get query
} --result "DELETE FROM sessions WHERE user_id = 7"
@example "an expression filter uses the raw --where" {
  mole-trino delete sessions --where "expires_at < now()" --dry-run | get query
} --result "DELETE FROM sessions WHERE expires_at < now()"
@example "guard: an unfiltered DELETE needs --all" {
  mole-trino delete staging_rows --all --dry-run | get query
} --result "DELETE FROM staging_rows"
export def "delete" [
  table: string@"trino-table"                      # target table (DELETE FROM <table>); single table, an alias is allowed: "customer c"
  --where(-w): string@"trino-where"                # WHERE: col<op>value token-list (comma-sep, completable) OR raw SQL
  --all                                            # allow an unfiltered DELETE (every row) when --where is omitted
  --connection(-c): string@complete-connection   # named connection (default: current)
  --host(-h): string
  --port(-p): int
  --user(-u): string
  --catalog: string                                # override catalog (Trino-specific)
  --schema: string                                 # override schema (Trino-specific)
  --set: record = {}
  --dry-run(-n)                                    # return a {connection, query} record instead of running
  --yes(-y)                                         # skip the confirmation prompt
] {
  # --where is dual-mode: a col<op>value token-list, or raw SQL when it doesn't parse.
  let where_sql = (sql build-where ($where | default "") --dialect $TRINO_DIALECT --ops (trino-ops))
  if ($where_sql | is-empty) and (not $all) {
    error make {msg: "delete: refusing to delete every row without --where (pass --all to override)"}
  }
  let text = (sql build-delete --table $table --where ($where_sql | default ""))
  let conf = (trino-conf $connection $host $port $user $catalog $schema $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (not (query confirm "This DELETE will remove rows. Run it?" --yes=$yes)) { return }
  trino-rows $conf $text
}

# Inspect a connection's cached schema (introspection is cached for a day).
#
# The default view is one summary row per table: schema, name, type, column
# count, primary key (always empty — Trino has no constraint metadata), row
# estimate (0), comment. `--table` switches to the full detail for one table (its
# columns; constraints are always empty); `--find` searches table and column
# names and comments case-insensitively; `--full` returns the raw cache record,
# including its `meta`. `--refresh` rebuilds the cache from the live server
# before reading. `--include`/`--exclude` (mutually exclusive) narrow the tables
# shown in EVERY view (comma-separated names — bare or `schema.`-qualified, `*`
# globs allowed), most
# useful with `--full` to feed `mole-mermaid` a diagram of just the tables you
# want. Connection is overridable exactly as in `raw-query`.
@category mole-trino
@example "summary — one row per table" {
  mole-trino schema -c trino-local-dev
}
@example "detail for one table (its columns)" {
  mole-trino schema --table customer -c trino-local-dev
}
@example "search names for 'key'" {
  mole-trino schema --find key -c trino-local-dev
}
@example "rebuild the cache from the live server first" {
  mole-trino schema --refresh -c trino-local-dev
}
@example "the raw cache record, including meta" {
  mole-trino schema --full -c trino-local-dev
}
@example "render only some tables as a Mermaid ER diagram" {
  mole-trino schema --full --include "customer,orders,lineitem" -c trino-local-dev | mole-mermaid er-schema
}
export def "schema" [
  --connection(-c): string@complete-connection   # named connection (default: current)
  --table(-t): string@"trino-table"                # detail view for one table
  --find: string                                   # find tables/columns by name or comment (case-insensitive)
  --refresh(-r)                                    # rebuild the cache before reading
  --full                                           # return the full cache record
  --include: string@"trino-tables-csv"             # keep ONLY these tables — comma-sep names/globs (mutually exclusive with --exclude)
  --exclude: string@"trino-tables-csv"             # drop these tables — comma-sep names/globs (mutually exclusive with --include)
  --host(-h): string                               # override host
  --port(-p): int                                  # override port
  --user(-u): string                               # override user
  --catalog: string                                # override catalog (Trino-specific)
  --schema: string                                 # override schema (Trino-specific)
  --set: record = {}                               # override any other connection field(s)
] {
  if ($include | is-not-empty) and ($exclude | is-not-empty) {
    error make {msg: "schema: --include and --exclude are mutually exclusive"}
  }
  let conf = (trino-conf $connection $host $port $user $catalog $schema $set)
  let data = (sql schema-filter (trino-schema-load $conf --refresh=$refresh) --include (sql csv-split $include) --exclude (sql csv-split $exclude))
  if $full { return $data }
  if ($find | is-not-empty) {
    sql schema-find $data $find
  } else if ($table | is-not-empty) {
    sql schema-detail $data $table
  } else {
    sql schema-tables $data
  }
}

# Make a trino connection the current one for this driver.
#
# Records the choice in `$env.MOLE_CURRENT.trino`, so later `raw-query` / `select` /
# `schema` calls can omit `--connection`. Validates that `name` exists and is
# actually a trino connection (errors otherwise). Being `--env`, the change
# persists in the caller's environment.
@category mole-trino
@example "make the local dev server current" {
  mole-trino set-connection trino-local-dev
}
export def --env "set-connection" [
  name: string@complete-connection   # a trino connection name (from the connections file)
]: nothing -> nothing {
  conn set-current trino $name | ignore
}
