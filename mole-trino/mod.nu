# mole-trino — Trino driver plugin.
#
# A PLUGIN (data source): supports the trino technology, registers itself as a
# driver, and exposes the user verbs `raw-query` / `select` / `stats` / `insert` / `update` / `delete` / `schema`. It DEPENDS on:
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

# The dialect's aggregate vocabulary: the ANSI base (count/sum/avg/min/max/count-distinct)
# plus Trino's `approx_distinct(col)` (HyperLogLog cardinality, typed int) →
# `approx_distinct_<col>` and its string aggregation `listagg(col, ',') WITHIN GROUP
# (ORDER BY col)` → `string_agg_<col>` (listagg needs Trino ≥ 359; verified on 483).
# Injected into `sql build-aggs` so `stats` can compute a dialect aggregate the ANSI set
# can't — the aggregate twin of `trino-ops`. The flag keys are the verb's own flag names,
# so `sql agg-requests` reads a `{count, sum, …, approx-distinct, string-agg}` record.
def "trino-aggs" []: nothing -> list {
  sql ansi-aggs
  | append {flag: "approx-distinct", fieldless: false, type: "int", render: {|col| $"approx_distinct\(($col)\)" }}
  | append {flag: "string-agg",      fieldless: false,              render: {|col| $"listagg\(($col), ','\) WITHIN GROUP \(ORDER BY ($col)\)" }}
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
def trino-exec [conf: record, sql: string, --probe]: nothing -> record {
  let server = $"($conf.host):($conf | get -o port | default 8080)"
  let bounds = (if $probe { ["--client-request-timeout" "3s"] } else { [] })   # completion-time bound
  (^trino
    --server $server
    --user ($conf | get -o user | default "admin")
    --catalog $conf.catalog
    --schema $conf.schema
    ...$bounds
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
  cache fetch $file 1day --refresh=$refresh {||
    let secs = [
        {k: "tables"      q: (trino-tables-sql)}
        {k: "columns"     q: (trino-columns-sql)}
        {k: "constraints" q: (trino-constraints-sql)}
      ]
      | par-each {|s| {key: $s.k, rows: (trino-rows $conf $s.q)} }
      | reduce --fold {} {|it, acc| $acc | upsert $it.key $it.rows }
    let body = (sql schema-body $secs.tables $secs.columns $secs.constraints {|c| trino-display-type $c } $TRINO_NULLS)
    {meta: {connection: $conf.name, catalog: $cat, schema: $sch, driver: "trino"}} | merge $body
  }
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

# Comma-list variant for `schema --include/--exclude` (see `complete csv-extend`).
def "trino-tables-csv" [context: string]: nothing -> list<string> {
  complete csv-extend $context (trino-table $context)
}

# The table a line targets: `--from` (select/stats), else the leading positional of the
# write verbs (`insert|update|delete <table>`); null when neither is typed yet.
def trino-ctx-table [context: string]: nothing -> any {
  complete flag $context [--from -F] | default (complete lead-arg $context [insert update delete])
}

def "trino-column" [context: string]: nothing -> list<string> {
  sql complete-columns (trino-catalog $context) (trino-ctx-table $context)
}

# Comma-list variant of `trino-column` for the multi-value column flags (`stats`'
# `--by`/`--sum`/`--avg`/…): re-prepend the already-typed columns so accepting a
# candidate extends the list (Nushell can't complete inside a `[...]` list literal).
def "trino-columns-csv" [context: string]: nothing -> list<string> {
  complete csv-extend $context (trino-column $context)
}

# `select`'s `--sort-by` completer: the source columns as `col[:desc]` sort tokens.
def "trino-sort" [context: string]: nothing -> list<string> { complete sort-csv $context (trino-column $context) }

# Completion-only distinct-value probe: `trino-exec --probe` (bounded); `[]` on any
# non-zero exit. The caller wraps it in `try` for parse errors.
def trino-probe [conf: record, sql: string]: nothing -> list<string> {
  let r = (trino-exec $conf $sql --probe)
  if ($r.exit_code != 0) { return [] }
  $r.stdout | from csv --no-infer | get -o v | default []
}

# `--where` completer. The three stages — columns → the dialect operators → live
# distinct values scoped to the sibling predicates — are planned by the pure
# `sql where-plan`; this only runs the bounded probe (best-effort: unreachable /
# slow / errored → nothing).
def "trino-where" [context: string]: nothing -> list<any> {
  let plan = (sql where-plan (complete token $context) (trino-column $context) --ops (trino-ops) --dialect $TRINO_DIALECT --table (trino-ctx-table $context))
  if ($plan.probe? == null) { return $plan.candidates }
  let conf = (complete conn-ctx $context "trino")
  if ($conf | is-empty) { return [] }
  (try { trino-probe $conf $plan.probe.sql } catch { [] }) | each {|v| $plan.probe.prefix + $v }
}

# The assignment-token completer of `insert` and `update` (their `...assignments` rest
# slot). Two stages, planned by the pure `sql assign-plan`: a token without `=` offers
# the target table's columns NOT yet assigned by the earlier tokens, as `col=`
# (described by type, plus `required` on an insert line when NOT NULL without a
# default); after `col=`, the column's live distinct values through the bounded probe
# (best-effort: unreachable / errored → nothing). The target is the leading positional
# (an update alias, `"users u"`, is looked up by its base table), the assigned set the
# positionals after it.
def "trino-assign" [context: string]: nothing -> list<any> {
  let table = (trino-ctx-table $context)
  let cols = (if ($table | is-empty) { [] } else { sql columns-for (trino-catalog $context) (sql base-table $table) })
  let assigned = (complete positionals $context | skip 1 | each {|t| sql assignment-token $t | get -o col } | compact)
  let insert = (complete lead-arg $context [insert] | is-not-empty)
  let plan = (sql assign-plan (complete token $context) $cols --assigned $assigned --table $table --required=$insert)
  if ($plan.probe? == null) { return $plan.candidates }
  let conf = (complete conn-ctx $context "trino")
  if ($conf | is-empty) { return [] }
  (try { trino-probe $conf $plan.probe.sql } catch { [] }) | each {|v| $plan.probe.prefix + $v }
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
# default `*`), passed to the `trino` CLI VERBATIM. The WHERE clause is `--where`, a comma-separated `col<op>value` token-list
# (`status=active,age>=30`, `name~%acme%`, `role=in:admin,ops`, `deleted=null`) whose
# columns AND operators tab-complete; anything else there is an error, never a guess.
# Raw SQL (an `OR`, a sub-select, `now()`) goes in `--where-sql`, AND-joined with it.
# Token operators are `= != > >= < <=`,
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
  mole-trino select custkey name acctbal --from customer --where-sql "acctbal > 5000" --sort-by acctbal:desc --limit 5 --dry-run | get query
} --result "SELECT custkey, name, acctbal FROM customer WHERE acctbal > 5000 ORDER BY acctbal DESC LIMIT 5"
@example "DISTINCT (Trino has no DISTINCT ON)" {
  mole-trino select mktsegment --distinct --from customer --dry-run | get query
} --result "SELECT DISTINCT mktsegment FROM customer"
@example "pagination — Trino's grammar puts OFFSET before LIMIT" {
  mole-trino select --from customer --sort-by custkey --limit 5 --offset 10 --dry-run | get query
} --result "SELECT * FROM customer ORDER BY custkey OFFSET 10 LIMIT 5"
@example "a --where token-list composes the WHERE clause (columns + operators complete)" {
  mole-trino select custkey name --from customer --where mktsegment=BUILDING,acctbal>=5000 --dry-run | get query
} --result "SELECT custkey, name FROM customer WHERE mktsegment = 'BUILDING' AND acctbal >= 5000"
@example "raw SQL goes in --where-sql" {
  mole-trino select --from customer --where-sql "acctbal > 0 AND mktsegment <> 'AUTOMOBILE'" --dry-run | get query
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
  --where(-w): string@"trino-where"                # WHERE: col<op>value token-list (comma-sep, completable)
  --where-sql: string                              # WHERE as raw SQL, verbatim — AND-joined with --where when both are given
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
] {
  if ($from | is-empty) { error make {msg: "select: --from <table> is required"} }
  # The rest slot is projection-only (commas optional); the filter is --where (tokens) / --where-sql (raw).
  let cols = ($columns | each {|c| $c | str trim --char "," } | where {|c| $c | is-not-empty })
  let text = (sql assemble [
    (trino-projection $cols $distinct)
    $"FROM ($from)"
    (sql where-clause $where $where_sql --dialect $TRINO_DIALECT --ops (trino-ops))
    (sql build-order (complete csv $sort_by))
    # Trino's grammar is `[OFFSET n] [LIMIT n]` — the reverse of the RDBMS siblings
    # (`LIMIT 5 OFFSET 10` is a syntax error on the server).
    (sql page-clause $limit $offset --offset-first)
  ])
  let conf = (trino-conf $connection $host $port $user $catalog $schema $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  # A composed SELECT can only ever read (no locks on this engine), so nothing to confirm.
  let rows = (trino-rows $conf $text)
  if $raw { return $rows }
  $rows | sql type-rows (trino-schema-load $conf) $from $TRINO_NULLS {|c| trino-type $c }
}

# ---- stats completers (result-column pool) ------------------------------------
# The RESULT columns of a `stats` line: the `--by` keys ++ the aggregate auto-names,
# reconstructed from the flags on the line via the SAME `sql result-cols` path the verb
# body uses (so completion and the generated SQL never drift). No I/O: the aggregate
# names come from the flags, not the schema, so this completes even without a reachable
# cluster.
def "trino-result-cols" [context: string]: nothing -> list<string> {
  # one flag per aggregate, read off the line by its `flag` name; `--count` is a switch
  let flags = (trino-aggs | reduce --fold {count: ($context =~ '(?:--count|-C)(?:\s|$)')} {|a, acc|
    if $a.fieldless { $acc } else { $acc | upsert $a.flag (complete csv (complete flag $context [("--" + $a.flag)])) }
  })
  sql result-cols (complete csv (complete flag $context [--by -g])) $flags (trino-aggs)
}

# `--having` completer: partial two-stage — complete the RESULT-column name; once an
# operator is typed the user fills the value. Comma-list aware.
def "trino-having" [context: string]: nothing -> list<string> {
  let seg = (complete token $context | split row "," | last)
  if (sql predicate-token $seg --ops (trino-ops)) != null { return [] }
  complete csv-extend $context (trino-result-cols $context)
}

# `--sort-by` completer over RESULT columns (`col[:desc]`), via the shared sort helper.
def "trino-rsort" [context: string]: nothing -> list<string> { complete sort-csv $context (trino-result-cols $context) }

# Compose and run a single-table Trino aggregation (GROUP BY), returning typed rows.
#
# The analytics twin of `select`: `stats` groups by `--by` keys and computes the
# per-function aggregate flags (`--count`, `--sum`, `--avg`, `--min`, `--max`,
# `--count-distinct`, plus the dialect's `--approx-distinct` and `--string-agg`), each
# auto-named SQL-style (`count`, `sum_<col>`, `avg_<col>`, `count_distinct_<col>`,
# `approx_distinct_<col>`, `string_agg_<col>`). `--where`/`--where-sql` is the PRE-aggregation
# filter — the same pair as `select`. `--having` filters
# the grouped rows with the same token grammar but over the RESULT columns (`count>=10`,
# `sum_amount>1000`) — the alias is expanded back to its aggregate expression, so it is
# portable across dialects; `count` is always available. `--sort-by` orders the RESULT
# columns (`col[:desc]`), and `--limit`/`--offset` page them (rendered `OFFSET … LIMIT …`,
# Trino's grammar order).
#
# No `--by` yields a grand total (one row); no aggregate flag defaults to `count(*)`.
# Group keys come back DB-typed from the schema; `count`/`count_distinct`/
# `approx_distinct` are ints and `avg`/`sum` floats (`min`/`max`/`string_agg` keep the
# source string unless you `--raw`). `--dry-run` returns `{connection, query}`.
# Aggregations only READ, so there is no prompt. Anything past this subset — joins,
# expression aggregates, GROUPING SETS, windows — is a `raw-query`. Connection
# overridable via `--connection` + per-field flags / `--catalog` / `--schema` / `--set`.
@category mole-trino
@example "count and sum per group, ordered, top-N" {
  mole-trino stats --from customer --by mktsegment --count --sum acctbal --sort-by sum_acctbal:desc --limit 10 --dry-run | get query
} --result "SELECT mktsegment, count(*) AS count, sum(acctbal) AS sum_acctbal FROM customer GROUP BY mktsegment ORDER BY sum_acctbal DESC LIMIT 10"
@example "pre-filter + HAVING over result columns (alias expands to the expression)" {
  mole-trino stats --from customer --by mktsegment,nationkey --count --avg acctbal --where acctbal>0 --having count>=10 --sort-by avg_acctbal:desc --dry-run | get query
} --result "SELECT mktsegment, nationkey, count(*) AS count, avg(acctbal) AS avg_acctbal FROM customer WHERE acctbal > 0 GROUP BY mktsegment, nationkey HAVING count(*) >= 10 ORDER BY avg_acctbal DESC"
@example "grand total — no --by" {
  mole-trino stats --from customer --count --sum acctbal --dry-run | get query
} --result "SELECT count(*) AS count, sum(acctbal) AS sum_acctbal FROM customer"
@example "paging — OFFSET renders before LIMIT" {
  mole-trino stats --from customer --by mktsegment --count --sort-by count:desc --limit 2 --offset 1 --dry-run | get query
} --result "SELECT mktsegment, count(*) AS count FROM customer GROUP BY mktsegment ORDER BY count DESC OFFSET 1 LIMIT 2"
@example "Trino dialect aggregates — approximate distinct nations and comma-joined names" {
  mole-trino stats --from customer --by mktsegment --approx-distinct nationkey --string-agg name --dry-run | get query
} --result "SELECT mktsegment, approx_distinct(nationkey) AS approx_distinct_nationkey, listagg(name, ',') WITHIN GROUP (ORDER BY name) AS string_agg_name FROM customer GROUP BY mktsegment"
@example "run for real — grouped rows come back DB-typed (tpch.tiny)" {
  mole-trino stats --from customer --by mktsegment --count --avg acctbal --catalog tpch --schema tiny -c trino-local-dev
}
export def "stats" [
  --from(-F): string@"trino-table"                 # source table, single table only (an alias is allowed: "customer c")
  --where(-w): string@"trino-where"                # WHERE: col<op>value token-list (comma-sep, completable; pre-aggregation)
  --where-sql: string                              # WHERE as raw SQL, verbatim — AND-joined with --where when both are given
  --by(-g): string@"trino-columns-csv"             # GROUP BY keys, comma-separated
  --count(-C)                                      # count(*) → `count`
  --sum: string@"trino-columns-csv"                # sum(col) → `sum_<col>`, comma-separated columns
  --avg: string@"trino-columns-csv"                # avg(col) → `avg_<col>`
  --min: string@"trino-columns-csv"                # min(col) → `min_<col>`
  --max: string@"trino-columns-csv"                # max(col) → `max_<col>`
  --count-distinct: string@"trino-columns-csv"     # count(distinct col) → `count_distinct_<col>`
  --approx-distinct: string@"trino-columns-csv"    # approx_distinct(col) → `approx_distinct_<col>` (Trino dialect aggregate)
  --string-agg: string@"trino-columns-csv"         # listagg(col, ',') WITHIN GROUP (ORDER BY col) → `string_agg_<col>` (Trino dialect aggregate)
  --having: string@"trino-having"                  # post-aggregation filter tokens over RESULT columns (AND-joined)
  --sort-by(-s): string@"trino-rsort"              # ORDER BY over RESULT columns: col[:desc], comma-separated
  --limit(-l): int                                 # LIMIT N
  --offset(-o): int                                # OFFSET N
  --connection(-c): string@complete-connection   # named connection (default: current)
  --host(-h): string
  --port(-p): int
  --user(-u): string
  --catalog: string                                # override catalog (Trino-specific)
  --schema: string                                 # override schema (Trino-specific)
  --set: record = {}
  --raw(-R)                                         # raw driver output: no typing, no null-normalization
  --dry-run(-n)                                    # return a {connection, query} record instead of running
] {
  if ($from | is-empty) { error make {msg: "stats: --from <table> is required"} }
  let by = (complete csv $by)
  let flags = {
    count: $count, sum: (complete csv $sum), avg: (complete csv $avg), min: (complete csv $min), max: (complete csv $max)
    "count-distinct": (complete csv $count_distinct), "approx-distinct": (complete csv $approx_distinct), "string-agg": (complete csv $string_agg)
  }
  let aggs = (sql build-aggs (sql agg-requests $flags (trino-aggs)) (trino-aggs))
  let proj = (($by ++ ($aggs | each {|a| $a.expr + " AS " + $a.name })) | str join ", ")
  let text = (sql assemble [
    $"SELECT ($proj)"
    $"FROM ($from)"
    (sql where-clause $where $where_sql --dialect $TRINO_DIALECT --ops (trino-ops))
    (sql join-list $by --prefix "GROUP BY ")
    (sql build-having (complete csv $having) $aggs --by $by --dialect $TRINO_DIALECT --ops (trino-ops))
    (sql build-order (complete csv $sort_by))
    (sql page-clause $limit $offset --offset-first)   # Trino: OFFSET before LIMIT (see `select`)
  ])
  let conf = (trino-conf $connection $host $port $user $catalog $schema $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  let rows = (trino-rows $conf $text)
  if $raw { return $rows }
  $rows | sql type-rows (trino-schema-load $conf) $from $TRINO_NULLS {|c| trino-type $c }
  | sql apply-agg-types $aggs
}

# Compose and run a Trino INSERT: one row from `col=value` tokens, or many rows
# from a piped table, into a single table.
#
# Reads like the statement: `insert <table> col=value …`. The table is the leading
# positional (completing table names); the rest positionals are `col=value` ASSIGNMENT
# tokens — the `--where` grammar cut down to `=`, with the same literal rules: a bare
# value is quoted by shape (`age=30` → `30`, `status=active` → `'active'`), a quoted one
# is always a string (`zip="01234"`), `col=null` is `NULL`. The columns complete (typed,
# `required` flagged when NOT NULL without a default) and, after `col=`, the column's
# existing distinct values do. An EXPRESSION (`now()`, `DEFAULT`, a function call) never
# goes through the token grammar: pass it in `--values-sql`, a record of
# `{column: "raw sql"}` rendered verbatim.
#
# PIPE a table in to insert many rows in ONE statement: each record's keys are the
# column list and its typed cells render by type (a string is always quoted, a
# record/list is JSON, null is NULL); any tokens / `--values-sql` entries become
# CONSTANT columns on every row. Ragged rows (differing key sets) are refused — shape
# them in Nushell first.
#
# Trino INSERT has no conflict handling and no RETURNING (writes are connector-dependent
# — reach for `raw-query` for `MERGE`). INSERT always writes, so it prompts before
# running (skip with `--yes`); `--dry-run` returns a `{connection, query}` record without
# running. Connection overridable as in `raw-query`.
@category mole-trino
@example "one row from tokens (columns, then existing values, complete)" {
  mole-trino insert users email=ann@x.io status=active --dry-run | get query
} --result "INSERT INTO users (email, status) VALUES ('ann@x.io', 'active')"
@example "many rows from a piped table, in one statement" {
  [{sku: A1, qty: 3} {sku: B2, qty: 0}] | mole-trino insert stock --dry-run | get query
} --result "INSERT INTO stock (sku, qty) VALUES ('A1', 3), ('B2', 0)"
@example "an expression value goes in --values-sql" {
  mole-trino insert events kind=login --values-sql {at: "now()"} --dry-run | get query
} --result "INSERT INTO events (kind, at) VALUES ('login', now())"
@example "run for real — load a CSV (prompts unless --yes)" {
  open signups.csv | mole-trino insert users -c trino-local-dev --yes
}
export def "insert" [
  table: string@"trino-table"                # target table (INSERT INTO <table>); single table, no alias
  ...assignments: string@"trino-assign"          # col=value tokens: the one row, or constant columns on every piped row
  --values-sql: record = {}                        # {column: "raw sql"}: expression values, verbatim (now(), DEFAULT, …)
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
  let parts = (sql insert-values $in --assignments $assignments --values-sql $values_sql --dialect $TRINO_DIALECT)
  let text = (sql build-insert --table $table --columns $parts.columns --rows $parts.values)
  let conf = (trino-conf $connection $host $port $user $catalog $schema $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (not (query confirm $"This INSERT will add ($parts.values | length) row\(s\). Run it?" --yes=$yes)) { return }
  trino-rows $conf $text
}

# Compose and run a single-table Trino UPDATE.
#
# Reads like the statement: `update <table> col=value …`. The table is the leading
# positional (completing table names); the rest positionals are `col=value`
# ASSIGNMENT tokens, the same grammar as `insert`: a bare value is quoted by shape
# (`age=30` → `30`, `status=active` → `'active'`), a quoted one is always a string
# (`zip="01234"`), `col=null` is `NULL`. The columns complete and, after `col=`, the
# column's existing distinct values do. An EXPRESSION (`hits + 1`, `now()`) never goes
# through the token grammar: pass it in `--values-sql`, a record of
# `{column: "raw sql"}` rendered verbatim. `--where`/`--where-sql` is
# the same filter pair as `select`. Trino UPDATE is connector-dependent and has no RETURNING,
# no ORDER BY/LIMIT and no join support — reach for `raw-query` for anything more.
#
# UPDATE always writes, so it prompts before running (skip with `--yes`) and
# REFUSES to touch every row unless you pass `--all`. `--dry-run` returns a
# `{connection, query}` record without running. Connection overridable via
# `--connection` + per-field flags / `--catalog` / `--schema` / `--set`.
@category mole-trino
@example "set a column on the matched rows" {
  mole-trino update users status=inactive --where-sql "id = 5" --dry-run | get query
} --result "UPDATE users SET status = 'inactive' WHERE id = 5"
@example "several assignments at once" {
  mole-trino update t a=1 b=2 --where-sql "id = 5" --dry-run | get query
} --result "UPDATE t SET a = 1, b = 2 WHERE id = 5"
@example "guard: an unfiltered UPDATE needs --all" {
  mole-trino update users archived=true --all --dry-run | get query
} --result "UPDATE users SET archived = true"
export def "update" [
  table: string@"trino-table"                      # target table (UPDATE <table>); single table, an alias is allowed: "customer c"
  ...assignments: string@"trino-assign"            # col=value tokens: the SET list (with --values-sql, at least one assignment)
  --values-sql: record = {}                        # {column: "raw sql"}: expression values, verbatim (hits + 1, now(), …)
  --where(-w): string@"trino-where"                # WHERE: col<op>value token-list (comma-sep, completable)
  --where-sql: string                              # WHERE as raw SQL, verbatim — AND-joined with --where when both are given
  --all                                            # allow an unfiltered UPDATE (every row) when no --where/--where-sql is given
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
  let sets = (sql render-assignments $assignments --values-sql $values_sql --dialect $TRINO_DIALECT)
  let filter = (sql build-where $where $where_sql --dialect $TRINO_DIALECT --ops (trino-ops))
  if ($filter | is-empty) and (not $all) {
    error make {msg: "update: refusing to update every row without --where/--where-sql (pass --all to override)"}
  }
  let text = (sql build-update --table $table --set $sets --where ($filter | default ""))
  let conf = (trino-conf $connection $host $port $user $catalog $schema $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $text} }
  if (not (query confirm "This UPDATE will modify rows. Run it?" --yes=$yes)) { return }
  trino-rows $conf $text
}

# Compose and run a single-table Trino DELETE.
#
# Reads like the statement: `delete <table> --where <predicate>`. The table is the
# leading positional (completing table names); `--where` is a comma-
# separated `col<op>value` token-list (`user_id=7`, `status=inactive`, `role=in:a,b`,
# `deleted=null`) whose columns and operators complete; raw SQL (an `OR`, `now()`,
# a sub-select) goes in `--where-sql` — the same pair as `select`. Trino DELETE is
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
@example "an expression filter uses --where-sql" {
  mole-trino delete sessions --where-sql "expires_at < now()" --dry-run | get query
} --result "DELETE FROM sessions WHERE expires_at < now()"
@example "guard: an unfiltered DELETE needs --all" {
  mole-trino delete staging_rows --all --dry-run | get query
} --result "DELETE FROM staging_rows"
export def "delete" [
  table: string@"trino-table"                      # target table (DELETE FROM <table>); single table, an alias is allowed: "customer c"
  --where(-w): string@"trino-where"                # WHERE: col<op>value token-list (comma-sep, completable)
  --where-sql: string                              # WHERE as raw SQL, verbatim — AND-joined with --where when both are given
  --all                                            # allow an unfiltered DELETE (every row) when no --where/--where-sql is given
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
  let filter = (sql build-where $where $where_sql --dialect $TRINO_DIALECT --ops (trino-ops))
  if ($filter | is-empty) and (not $all) {
    error make {msg: "delete: refusing to delete every row without --where/--where-sql (pass --all to override)"}
  }
  let text = (sql build-delete --table $table --where ($filter | default ""))
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
  let data = (sql schema-filter (trino-schema-load $conf --refresh=$refresh) --include (complete csv $include) --exclude (complete csv $exclude))
  sql schema-view $data --table ($table | default "") --find ($find | default "") --full=$full
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
