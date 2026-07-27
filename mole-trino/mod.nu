# mole-trino — Trino driver plugin.
#
# A PLUGIN (data source): supports the trino technology, registers itself as a
# driver, and exposes the user verbs `query` / `select` / `schema`. It DEPENDS on:
#   - mole core plumbing        (`use mole/lib/*.nu`)
#   - the generic mole-sql pure LIBRARY (`use mole-sql/sql.nu`)
# The library dependency is also declared in mole.nuon (`deps`) so `mole
# submodules doctor` can verify it's installed and version-compatible.
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

const HERE = (path self | path dirname)

export-env {
  let m = (open ([$HERE mole.nuon] | path join))
  $env.MOLE_REGISTRY = (($env.MOLE_REGISTRY? | default {}) | upsert $m.driver $m)
  $env.MOLE_CURRENT = ($env.MOLE_CURRENT? | default {})
}

# ---- dialect specifics (trino) ------------------------------------------------

# How Trino's CSV_HEADER output renders a SQL NULL: an empty field. Injected into
# the mole-sql normalizers so the pure library carries no knowledge of NULL
# spelling.
const TRINO_NULLS = [""]

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

def "trino-table" [context: string]: nothing -> list<string> {
  try {
    let conf = (conn with trino (sql parse-flag $context ["--connection" "-c"]) {})
    sql complete-tables (trino-schema-load $conf | default {})
  } catch { [] }
}

def "trino-column" [context: string]: nothing -> list<string> {
  try {
    let conf = (conn with trino (sql parse-flag $context ["--connection" "-c"]) {})
    let tbl = (sql parse-flag $context ["--from" "-F"])
    sql complete-columns (trino-schema-load $conf | default {}) $tbl
  } catch { [] }
}

# ---- SELECT clause renderers (trino-specific) ---------------------------------

# SELECT head: `SELECT [DISTINCT] <cols>` (cols verbatim). Trino has no DISTINCT ON.
def trino-projection [columns: list<string>, distinct: bool]: nothing -> string {
  let cols = if ($columns | is-empty) { "*" } else { $columns | str join ", " }
  $"SELECT (if $distinct { 'DISTINCT ' } else { '' })($cols)"
}

# One ORDER BY term: "<expr> [ASC|DESC] [NULLS FIRST|LAST]" (expr verbatim).
# Trino supports NULLS FIRST/LAST.
def trino-order-term [term: string]: nothing -> string {
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
def trino-order [sort_by: any]: nothing -> any {
  if ($sort_by | is-empty) { return null }
  let terms = ($sort_by | split row "," | each {|t| trino-order-term $t } | where {|t| $t | is-not-empty })
  sql join-list $terms --prefix "ORDER BY "
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
# Named `query`, not `run`, because `run` is a Nushell parser keyword. Reference
# invocations (leaf verb — call it as your loader exposes it, e.g. `mole-trino query`):
#
#   mole-trino query "SELECT 1 AS n"                                    # the current connection
#   mole-trino query "SELECT custkey, name FROM customer LIMIT 5" -c trino-local-dev
#   mole-trino query --file reports/top-customers -c trino-local-dev    # <querydir>/reports/top-customers.sql
#   mole query show reports/top-customers.sql | mole-trino query -c trino-local-dev  # query text piped via stdin
#   mole-trino query "SELECT * FROM lineitem" -c trino-local-dev --catalog tpch --schema sf1
@category mole-trino
export def "query" [
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
  if (sql is-dangerous $text (trino-dangerous)) and (not (query confirm "This query may modify data. Run it?" --yes=$yes)) {
    return
  }
  trino-rows $conf $text
}

# Compose and run a single-table Trino SELECT, returning DB-typed rows.
#
# Clause bodies (columns, --where, --having, --sort-by terms) are passed to the
# `trino` CLI VERBATIM — expressions like `count(*)`, `lower(x)` work; quote
# reserved identifiers yourself. There is NO join support: the query always reads
# the single `--from` table. Only the `--from` table's cached columns are
# DB-typed; computed/aliased columns come back as lossless strings (use --raw to
# skip typing entirely). --dry-run returns a {connection, query} record without running (secrets dropped). Connection is
# overridable via --connection + per-field flags / --catalog / --schema / --set.
# Trino has no row locking, so there are no `--lock*` flags.
@category mole-trino
@example "every column of a table" {
  mole-trino select --from customer --dry-run | get query
} --result "SELECT * FROM customer"
@example "project, filter, order and limit" {
  mole-trino select custkey name acctbal --from customer --where "acctbal > 5000" --sort-by "acctbal desc" --limit 5 --dry-run | get query
} --result "SELECT custkey, name, acctbal FROM customer WHERE acctbal > 5000 ORDER BY acctbal DESC LIMIT 5"
@example "DISTINCT (Trino has no DISTINCT ON)" {
  mole-trino select mktsegment --distinct --from customer --dry-run | get query
} --result "SELECT DISTINCT mktsegment FROM customer"
@example "aggregate with GROUP BY and HAVING" {
  mole-trino select custkey "count(*) AS n" --from orders --group-by [custkey] --having "count(*) > 5" --sort-by "n desc" --dry-run | get query
} --result "SELECT custkey, count(*) AS n FROM orders GROUP BY custkey HAVING count(*) > 5 ORDER BY n DESC"
@example "ORDER BY ... NULLS LAST" {
  mole-trino select name acctbal --from customer --sort-by "acctbal desc nulls last" --dry-run | get query
} --result "SELECT name, acctbal FROM customer ORDER BY acctbal DESC NULLS LAST"
@example "pagination with LIMIT + OFFSET" {
  mole-trino select --from customer --sort-by custkey --limit 5 --offset 10 --dry-run | get query
} --result "SELECT * FROM customer ORDER BY custkey LIMIT 5 OFFSET 10"
@example "run for real — choose catalog/schema explicitly (tpch.tiny)" {
  mole-trino select custkey name acctbal --from customer --catalog tpch --schema tiny -c trino-local-dev
}
export def "select" [
  ...columns: string@"trino-column"                # projected columns/expressions (default: *)
  --from(-F): string@"trino-table"                 # source table, single table only (an alias is allowed: "customer c")
  --where(-w): string                              # WHERE predicate (without the keyword)
  --group-by(-g): list<string>@"trino-column"      # GROUP BY keys
  --having: string                                 # HAVING predicate (without the keyword)
  --sort-by(-s): string                            # ORDER BY terms, comma-separated: "col [asc|desc] [nulls first|last]"
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
  let text = (sql assemble [
    (trino-projection $columns $distinct)
    $"FROM ($from)"
    (if ($where | is-not-empty) { $"WHERE ($where)" })
    (sql join-list ($group_by | default []) --prefix "GROUP BY ")
    (if ($having | is-not-empty) { $"HAVING ($having)" })
    (trino-order $sort_by)
    (if $limit != null { $"LIMIT ($limit)" })
    (if $offset != null { $"OFFSET ($offset)" })
  ])
  let conf = (trino-conf $connection $host $port $user $catalog $schema $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (sql is-dangerous $text (trino-dangerous)) and (not (query confirm "This query may modify data. Run it?" --yes=$yes)) {
    return
  }
  let rows = (trino-rows $conf $text)
  if $raw { return $rows }
  $rows
  | sql normalize-nulls $TRINO_NULLS
  | sql apply-types (sql columns-for (trino-schema-load $conf) (sql base-table $from)) {|c| trino-type $c }
}

# Inspect a connection's cached schema (introspection is cached for a day).
#
# The default view is one summary row per table: schema, name, type, column
# count, primary key (always empty — Trino has no constraint metadata), row
# estimate (0), comment. `--table` switches to the full detail for one table (its
# columns; constraints are always empty); `--find` searches table and column
# names and comments case-insensitively; `--full` returns the raw cache record,
# including its `meta`. `--refresh` rebuilds the cache from the live server
# before reading. Connection is overridable exactly as in `query`.
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
export def "schema" [
  --connection(-c): string@complete-connection   # named connection (default: current)
  --table(-t): string@"trino-table"                # detail view for one table
  --find: string                                   # find tables/columns by name or comment (case-insensitive)
  --refresh(-r)                                    # rebuild the cache before reading
  --full                                           # return the full cache record
  --host(-h): string                               # override host
  --port(-p): int                                  # override port
  --user(-u): string                               # override user
  --catalog: string                                # override catalog (Trino-specific)
  --schema: string                                 # override schema (Trino-specific)
  --set: record = {}                               # override any other connection field(s)
] {
  let conf = (trino-conf $connection $host $port $user $catalog $schema $set)
  let data = (trino-schema-load $conf --refresh=$refresh)
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
# Records the choice in `$env.MOLE_CURRENT.trino`, so later `query` / `select` /
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
  conn resolve $name --driver trino | ignore
  $env.MOLE_CURRENT = (($env.MOLE_CURRENT? | default {}) | upsert trino $name)
}
