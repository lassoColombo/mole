# mole-myql — the MySQL-DIALECT shared library (MySQL + MariaDB + Percona).
#
# NOT a plugin/driver: it neither registers a driver nor talks to a CLI. It is the
# middle tier between the generic, dialect-agnostic `mole-sql` and the two engine
# plugins that speak the MySQL dialect over the MySQL wire protocol:
#
#     mole-sql          generic SQL toolkit  (assemble, join-list, apply-types, …)
#        ▲
#     mole-myql         THIS FILE — the MySQL dialect (information_schema SQL,
#        ▲              batch NULL spelling, WITH ROLLUP / LOCK IN SHARE MODE, the
#        │              tinyint(1)→bool + numeric/date type coercions)
#     ┌──┴───────────┐
#  mole-mysql   mole-mariadb   the engines: each owns only what truly differs —
#                              its client binary (`^mysql` vs `^mariadb`) and its
#                              JSON policy (native JSON vs the LONGTEXT alias).
#
# LAYERING: this is a pure library — it imports ONLY `mole-sql` (itself pure) and
# does no I/O (no connection, no CLI, no cache, no `$env`). Everything here is
# data-in / data-out, so it is shared VERBATIM by both engines; the two genuine
# divergences (binary + JSON typing) are NOT expressed here — they live in each
# driver, injected at the call site exactly like `mole-sql` takes type maps as
# closures. Discovered via `NU_LIB_DIRS`; no manifest, no registration.

use mole-sql/sql.nu

# ---- dialect constants --------------------------------------------------------

# How the `mysql`/`mariadb` batch (tab-separated) output renders a SQL NULL: the
# literal text `NULL` (an empty field is a genuine empty string). Fed to the
# `mole-sql` normalizers so the generic library carries no NULL-spelling knowledge.
@category mole-myql
@example "the batch-mode NULL placeholder" { myql nulls } --result ["NULL"]
export def "nulls" []: nothing -> list<string> { ["NULL"] }

# Statements that warrant a confirmation prompt before running (writes, DDL,
# grants, admin). A superset guard, identical across MySQL and MariaDB.
@category mole-myql
export def "dangerous" []: nothing -> string {
  '(?i)\b(delete|drop|truncate|update|insert|replace|create|alter|rename|grant|revoke|lock|unlock|analyze|optimize|repair|flush|kill|shutdown|load\s+data|outfile|dumpfile|call|execute|prepare|deallocate|set\s+global)\b'
}

# The completion values for a row lock: FOR UPDATE / FOR SHARE, plus the legacy
# LOCK IN SHARE MODE spelling.
@category mole-myql
@example "lock modes offered by --lock" { myql lock-modes } --result [update, share, share-mode]
export def "lock-modes" []: nothing -> list<string> { [update share share-mode] }

# ---- information_schema introspection -----------------------------------------
# All three SELECTs `AS`-alias to the common column names the `mole-sql` schema
# helpers expect, and exclude the server's own system schemas. MariaDB exposes the
# same information_schema shape, so these are shared unchanged.

@category mole-myql
export def "tables-sql" []: nothing -> string {
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

@category mole-myql
export def "columns-sql" []: nothing -> string {
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

@category mole-myql
export def "constraints-sql" []: nothing -> string {
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

# ---- result typing ------------------------------------------------------------

# The human-facing column type: MySQL/MariaDB give us the full `column_type`
# (e.g. "varchar(255)", "tinyint(1)", "int unsigned") via `udt_name`; fall back to
# the bare `data_type` when it is missing.
@category mole-myql
@example "the full column type wins over the bare data_type" {
  myql display-type {data_type: varchar, udt_name: "varchar(255)"}
} --result "varchar(255)"
export def "display-type" [c: record]: nothing -> string {
  let ct = ($c | get -o udt_name)
  if ($ct | is-not-empty) { ($ct | into string) } else { ($c.data_type | into string) }
}

# The cell converter for the type-SHARED columns — the coercions MySQL and MariaDB
# agree on. Returns a `null`-safe closure, or `null` to leave the column a string.
# By convention `tinyint(1)` is a boolean. JSON is deliberately NOT handled here:
# it is the one divergence (MySQL has a native `json` type; MariaDB's `JSON` is a
# `LONGTEXT` alias, indistinguishable from plain text), so each engine layers its
# own JSON policy on top of this.
@category mole-myql
@example "tinyint(1) is a boolean" {
  "1" | do (myql cell-type {data_type: tinyint, display_type: "tinyint(1)"})
} --result true
@example "an unknown/text type is left alone" {
  myql cell-type {data_type: varchar}
} --result null
export def "cell-type" [col: record]: nothing -> any {
  if (($col | get -o data_type) == "tinyint") and (($col | get -o display_type) == "tinyint(1)") {
    return (sql null-or {|x| ($x | into int) != 0 })
  }
  match ($col | get -o data_type) {
    "tinyint" | "smallint" | "mediumint" | "int" | "bigint" => (sql null-or {|x| $x | into int })
    "float" | "double" | "decimal" => (sql null-or {|x| $x | into float })
    "date" | "datetime" | "timestamp" => (sql null-or {|x| $x | into datetime })
    _ => null
  }
}

# ---- SELECT clause renderers --------------------------------------------------
# Each renders one MySQL-dialect clause body from already-validated inputs; the
# driver's `select` orders them through `sql assemble`.

# SELECT head: `SELECT [DISTINCT] <cols>` (cols verbatim). MySQL has no DISTINCT ON.
@category mole-myql
@example "distinct projection" { myql projection [status] true } --result "SELECT DISTINCT status"
export def "projection" [columns: list<string>, distinct: bool]: nothing -> string {
  let cols = if ($columns | is-empty) { "*" } else { $columns | str join ", " }
  $"SELECT (if $distinct { 'DISTINCT ' } else { '' })($cols)"
}

# One ORDER BY term: "<expr> [ASC|DESC]" (expr verbatim). MySQL has no NULLS ordering.
@category mole-myql
@example "normalize a sort direction" { myql order-term "age desc" } --result "age DESC"
export def "order-term" [term: string]: nothing -> string {
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
@category mole-myql
@example "compose an ORDER BY clause" {
  myql order "salary desc, name asc"
} --result "ORDER BY salary DESC, name ASC"
export def "order" [sort_by: any]: nothing -> any {
  if ($sort_by | is-empty) { return null }
  let terms = ($sort_by | split row "," | each {|t| order-term $t } | where {|t| $t | is-not-empty })
  sql join-list $terms --prefix "ORDER BY "
}

# Locking tail. "share-mode" → legacy `LOCK IN SHARE MODE` (no OF/wait policy);
# "update"/"share" → `FOR UPDATE`/`FOR SHARE` [OF ...] [SKIP LOCKED|NOWAIT]. null if unset.
@category mole-myql
@example "FOR UPDATE with a wait policy" {
  myql lock "update" [] true false
} --result "FOR UPDATE SKIP LOCKED"
@example "the legacy shared-read spelling" {
  myql lock "share-mode" [] false false
} --result "LOCK IN SHARE MODE"
export def "lock" [lock: any, lock_of: list<string>, skip_locked: bool, nowait: bool]: nothing -> any {
  if ($lock | is-empty) { return null }
  if (($lock | str lowercase) == "share-mode") { return "LOCK IN SHARE MODE" }
  let mode = if (($lock | str lowercase) == "share") { "FOR SHARE" } else { "FOR UPDATE" }
  let wait = if $skip_locked { "SKIP LOCKED" } else if $nowait { "NOWAIT" } else { null }
  sql assemble [$mode (sql join-list $lock_of --prefix "OF ") $wait]
}
