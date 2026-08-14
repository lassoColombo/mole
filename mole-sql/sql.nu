# mole-sql — generic SQL LIBRARY (dialect-agnostic). Not a plugin/driver: it
# exposes shared helpers that dialect plugins (mole-psql, mole-mysql) import via
# `use mole-sql/sql.nu` (→ `sql build-select`, …). No export-env, no driver
# registration, no manifest — a pure library discovered via `NU_LIB_DIRS`.
#
# LAYERING: this file is a PURE library — it `use`s NOTHING (not mole core, not
# any submodule) and every command is data-in / data-out with no I/O. Anything
# that touches a connection, a CLI, the cache, or the environment lives in the
# dialect PLUGIN, which orchestrates by composing these helpers. Dialect-varying
# behaviour is INJECTED, never hardcoded here: type maps and display-type
# synthesis as CLOSURES, and the CLI's NULL placeholder(s) — how it serializes a
# SQL NULL to text (`[""]` for psql --csv, `["NULL"]` for mysql batch) — as a
# `nulls: list<string>` parameter. The library assumes NOTHING about a dialect.
#
# Plugins feed introspection rows to the schema helpers using these COMMON
# column aliases (their SQL must `AS`-alias to exactly these names):
#   tables      → {schema, name, type, comment, row_estimate}
#   columns     → {schema, table, name, position, data_type, udt_name,
#                  is_nullable, default, char_max_length, numeric_precision,
#                  numeric_scale, comment}
#   constraints → {schema, table, name, type, columns, ref_schema, ref_table,
#                  ref_columns}
# `schema-body` normalizes those into the cached record a plugin writes:
#   {meta, tables, columns, constraints} — the shape the display/typing helpers
#   and the completers all read back.
#
# GOTCHA — builtin shadowing across the module boundary: a dialect plugin exports
# verbs whose leaf names collide with builtins this library calls — `select`,
# `insert`, `update`. Nushell re-resolves an imported function's UNQUALIFIED
# command calls in the IMPORTER's scope, so a bare `select` here would bind to the
# plugin's `select` verb instead of the builtin and break (even a *private* def in
# the plugin does this — so the fix must live here, not there). We defuse it by
# aliasing those builtins below, IN THIS FILE'S scope where the names still mean
# the builtin; the aliases resolve here and survive import. Call any builtin a
# plugin might expose as a verb through its alias, never by its bare name.
alias core-select = select
alias core-insert = insert
alias core-update = update

# ---- query building -----------------------------------------------------------

# Join pre-rendered clause fragments into one statement, in the given order.
#
# The universal SELECT-assembly primitive: it decides NOTHING about SQL — the
# caller renders each clause (with its own dialect keywords, quoting, ordering)
# and hands them here already ordered; empty/null fragments are dropped and the
# rest are space-joined. This is the only "query shape" logic shared across
# dialects; everything keyword-specific lives in the plugins.
@category mole-sql
@example "empty fragments are dropped" {
  sql assemble ["SELECT *" "FROM t" null "" "LIMIT 5"]
} --result "SELECT * FROM t LIMIT 5"
export def "assemble" [
  fragments: list<any>   # ordered clause strings; null/"" are dropped
]: nothing -> string {
  $fragments | where {|f| $f | is-not-empty } | str join " "
}

# Comma-join a list into a clause body, or null when the list is empty (so the
# whole clause drops in `assemble`). Optional `--prefix` prepends a keyword.
# Universal: the comma-list shape is identical across SQL dialects (projections,
# GROUP BY keys, ORDER BY terms, DISTINCT ON lists, FOR ... OF tables).
@category mole-sql
@example "prefix a non-empty list" {
  sql join-list [a b c] --prefix "GROUP BY "
} --result "GROUP BY a, b, c"
@example "empty list drops the clause" {
  sql join-list [] --prefix "GROUP BY "
} --result null
export def "join-list" [
  items: list<string>       # list to comma-join; empty/null entries are dropped
  --prefix: string = ""     # keyword to prepend when the result is non-empty
]: nothing -> any {
  let clean = ($items | where {|i| $i | is-not-empty })
  if ($clean | is-empty) { null } else { $prefix + ($clean | str join ", ") }
}

# The base table of a (possibly aliased, possibly schema-qualified) FROM ref:
# its first whitespace-delimited token. `"users u"` -> `"users"`,
# `"public.users"` -> `"public.users"`. Lets a plugin look the table up in the
# schema cache (for typing/completion) even when the user aliased it.
@category mole-sql
@example "strip a table alias" { sql base-table "users u" } --result "users"
export def "base-table" [ref: string]: nothing -> string {
  $ref | str trim | split row " " | first
}

# Build an ANSI `SELECT` statement from its parts, dialect-agnostic.
#
# Clauses are emitted in fixed order (SELECT/FROM/WHERE/ORDER BY/LIMIT) and empty
# ones are dropped, so the result is always valid standard SQL. `--from` is the
# only required part; omitting `--columns` projects `*`. Dialects that need
# non-standard syntax can post-process this string or build their own.
@category mole-sql
@example "just a table projects every column" {
  sql build-select --from "users"
} --result "SELECT * FROM users"
@example "explicit columns are comma-joined" {
  sql build-select --columns [id name] --from "users"
} --result "SELECT id, name FROM users"
@example "all clauses compose in order" {
  sql build-select --columns [id] --from users --where "age > 18" --sort-by name --limit 10
} --result "SELECT id FROM users WHERE age > 18 ORDER BY name LIMIT 10"
export def "build-select" [
  --columns: list<string> = []   # projected columns (default: *)
  --from: string                 # source table (required)
  --where: string                # WHERE clause, without the keyword
  --sort-by: string              # ORDER BY clause, without the keyword
  --limit: int                   # LIMIT N
]: nothing -> string {
  if ($from | is-empty) { error make {msg: "sql build-select: --from <table> is required"} }
  let cols = if ($columns | is-empty) { "*" } else { $columns | str join ", " }
  assemble [
    $"SELECT ($cols) FROM ($from)"
    (if ($where | is-not-empty) { $"WHERE ($where)" })
    (if ($sort_by | is-not-empty) { $"ORDER BY ($sort_by)" })
    (if $limit != null { $"LIMIT ($limit)" })
  ]
}

# Build an ANSI `UPDATE` statement from its parts, dialect-agnostic.
#
# Emits `UPDATE <table> SET <assignments> [WHERE ...] [RETURNING ...]` in fixed
# order, dropping empty clauses. Each assignment is a verbatim `"col = expr"`
# string (the caller quotes identifiers/literals), comma-joined into the SET body.
# `--table` and at least one assignment are required — an assignment-less UPDATE
# is a syntax error, and a `SET` with no body would silently corrupt the
# statement. `--returning` is the Postgres/DuckDB output clause; dialects without
# it (MySQL, Trino) simply pass `[]`. Non-standard tails a dialect appends after
# WHERE (MySQL's `ORDER BY ... LIMIT`) are added by the plugin around this core,
# exactly as `build-select` leaves DISTINCT ON / locking to the caller.
@category mole-sql
@example "one assignment, filtered" {
  sql build-update --table users --set ["status = 'inactive'"] --where "id = 5"
} --result "UPDATE users SET status = 'inactive' WHERE id = 5"
@example "expression assignment + RETURNING" {
  sql build-update --table users --set ["hits = hits + 1"] --where "id = 5" --returning [id hits]
} --result "UPDATE users SET hits = hits + 1 WHERE id = 5 RETURNING id, hits"
export def "build-update" [
  --table: string                 # target table (required)
  --set: list<string> = []        # SET assignments, verbatim "col = expr" (≥1 required)
  --where: string                 # WHERE predicate, without the keyword
  --returning: list<string> = []  # RETURNING columns (Postgres/DuckDB); dropped when empty
]: nothing -> string {
  if ($table | is-empty) { error make {msg: "sql build-update: --table <table> is required"} }
  if ($set | is-empty) { error make {msg: "sql build-update: at least one --set assignment is required"} }
  assemble [
    $"UPDATE ($table)"
    (join-list $set --prefix "SET ")
    (if ($where | is-not-empty) { $"WHERE ($where)" })
    (join-list $returning --prefix "RETURNING ")
  ]
}

# Build an ANSI `DELETE` statement from its parts, dialect-agnostic.
#
# Emits `DELETE FROM <table> [WHERE ...] [RETURNING ...]`, dropping empty clauses.
# `--table` is required; a missing `--where` deletes every row — this pure builder
# stays mechanical, so the "refuse an unfiltered DELETE unless --all" guard lives
# in the dialect plugin, not here. `--returning` is the Postgres/DuckDB output
# clause; other dialects pass `[]`.
@category mole-sql
@example "filtered delete" {
  sql build-delete --table sessions --where "expires_at < now()"
} --result "DELETE FROM sessions WHERE expires_at < now()"
@example "delete returning the removed rows" {
  sql build-delete --table sessions --where "id = 5" --returning ["*"]
} --result "DELETE FROM sessions WHERE id = 5 RETURNING *"
export def "build-delete" [
  --table: string                 # target table (required)
  --where: string                 # WHERE predicate, without the keyword
  --returning: list<string> = []  # RETURNING columns (Postgres/DuckDB); dropped when empty
]: nothing -> string {
  if ($table | is-empty) { error make {msg: "sql build-delete: --table <table> is required"} }
  assemble [
    $"DELETE FROM ($table)"
    (if ($where | is-not-empty) { $"WHERE ($where)" })
    (join-list $returning --prefix "RETURNING ")
  ]
}

# ---- result typing ------------------------------------------------------------

# Wrap a cell-coercion closure so a `null` cell survives as `null`.
#
# The returned closure reads the incoming cell via `$in`: a real `null` stays
# `null`; anything else is passed to `convert`. It is DIALECT-AGNOSTIC — it makes
# NO assumption about how a CLI spells NULL. The dialect's NULL placeholder is
# turned into a real `null` upstream, at the parse boundary (`normalize-nulls` for
# results, `schema-body` for introspection), so by the time a type-map converter
# runs a NULL is already a real `null`. This is the building block every dialect
# uses for its type map, e.g. `null-or {|x| $x | into int }`.
@category mole-sql
@example "the converter runs on a real value" {
  let to_int = sql null-or {|x| $x | into int }
  "42" | do $to_int
} --result 42
@example "a real null passes through untouched" {
  let to_int = sql null-or {|x| $x | into int }
  null | do $to_int
} --result null
export def "null-or" [
  convert: closure   # coercion to run on non-null cells, reading the cell via `$in`
]: nothing -> closure {
  {|| if $in == null { null } else { do $convert $in } }
}

# Pull the cached column records for one table out of a schema-cache record.
#
# `table` may be bare (`"users"`) or schema-qualified (`"public.users"`); the
# qualified form matches on both schema and name, so it disambiguates a table
# name that exists in more than one schema. Returns the matching column records
# (empty list if none) — feed them to `apply-types` or read `.name` for
# completion.
@category mole-sql
@example "columns of a table, by bare name" {
  let data = {columns: [
    {schema: public, table: users, name: id}
    {schema: public, table: users, name: email}
  ]}
  sql columns-for $data "users" | get name
} --result [id, email]
export def "columns-for" [
  data: record    # a schema-cache record (needs at least a `columns` list)
  table: string   # target table, `"name"` or `"schema.name"`
]: nothing -> list<any> {
  let cols = ($data | get -o columns | default [])
  let parts = ($table | split row ".")
  if ($parts | length) >= 2 {
    let sch = ($parts | first)
    let tbl = ($parts | skip 1 | str join ".")
    $cols | where schema == $sch and table == $tbl
  } else {
    $cols | where table == $table
  }
}

# Coerce the cells of a piped table, column by column, using injected converters.
#
# `convert` is asked, per column record, for a cell-converter closure (typically
# one built with `null-or`) or `null` to leave that column untouched. Columns
# that the converter maps to `null`, and columns not present in the piped rows,
# are passed through unchanged — so it is safe to hand it the full cached column
# set even for a partial projection. This is how a dialect turns the all-strings
# lossless parse into DB-typed rows.
@category mole-sql
@example "coerce id to int, leave name as a string" {
  let cols = [{name: id, data_type: integer} {name: name, data_type: text}]
  let typer = {|col| if $col.data_type == "integer" { sql null-or {|x| $x | into int } } else { null } }
  [{id: "1", name: "Ann"}] | sql apply-types $cols $typer
} --result [{id: 1, name: Ann}]
export def "apply-types" [
  columns: list<any>   # cached column records for the result's table (e.g. from `columns-for`)
  convert: closure     # maps a column record → a cell-converter closure, or null to skip: {|col: record| -> closure|null }
]: any -> any {
  let rows = $in
  let present = (try { $rows | columns } catch { [] })
  $columns
  | where name in $present
  | reduce --fold $rows {|col, acc|
      let conv = (do $convert $col)
      if $conv == null { $acc } else { $acc | core-update $col.name $conv }
    }
}

# Turn the dialect's NULL placeholder into a real `null` across EVERY column.
#
# Lossless CSV/TSV parsing leaves a SQL NULL as whatever the CLI printed, and that
# rendering is DIALECT-SPECIFIC — an empty string for `psql --csv`, the literal
# `"NULL"` for mysql batch tsv, etc. The caller passes its placeholder(s) in
# `nulls`; every string cell equal to one becomes `null`, all other cells (and
# non-strings) are untouched. A dialect calls this on a `select` result before
# `apply-types`, so computed / aliased columns read a real `null` too
# (not `""` here and `"NULL"` there). Deliberately NOT used on the lossless
# `query` / `--raw` path, which returns exactly what the driver printed.
@category mole-sql
@example "cells matching the dialect's placeholder(s) become null" {
  [{a: "", b: "NULL", c: "x", d: "0"}] | sql normalize-nulls ["" "NULL"]
} --result [{a: null, b: null, c: "x", d: "0"}]
export def "normalize-nulls" [
  nulls: list<string>   # the dialect's NULL placeholder string(s); a cell equal to one → `null`
]: any -> any {
  let rows = $in
  let cols = (try { $rows | columns } catch { [] })
  $cols | reduce --fold $rows {|c, acc| $acc | core-update $c {|| nullify-val $in $nulls } }
}

# ---- schema normalization -----------------------------------------------------

# A cell holding one of the dialect's NULL placeholders → real `null`. `nulls` is
# injected by the caller (e.g. `[""]` for psql, `["NULL"]` for mysql) — the
# library never assumes a spelling. A real `null` stays `null`; every other value
# (and non-strings) passes through unchanged.
def nullify-val [x: any, nulls: list<string>]: nothing -> any {
  if $x == null { return null }
  if ($x | describe) == "string" and ($x in $nulls) { return null }
  $x
}

# nullify (against the dialect placeholders), then best-effort int.
def try-int [x: any, nulls: list<string>]: nothing -> any {
  let n = (nullify-val $x $nulls)
  if $n == null { return null }
  if ($n | describe) == "int" { return $n }
  try { $n | into int } catch { null }
}

# Normalize raw `tables` introspection rows into their cached shape.
#
# Coerces `row_estimate` to an int (best-effort; unparseable → null) and turns a
# comment holding one of the dialect's NULL placeholders (`nulls`) into a real
# `null`. All other fields pass through. Input rows must already carry the common
# table aliases ({schema, name, type, comment, row_estimate}); see the file header.
@category mole-sql
@example "row_estimate → int, placeholder comment → null" {
  sql normalize-tables [{schema: public, name: users, type: "BASE TABLE", comment: "", row_estimate: "5"}] [""]
} --result [{schema: public, name: users, type: "BASE TABLE", comment: null, row_estimate: 5}]
export def "normalize-tables" [
  rows: list<any>       # raw table rows using the common `tables` aliases
  nulls: list<string>   # the dialect's NULL placeholder string(s)
]: nothing -> list<any> {
  $rows | each {|t|
    $t
    | core-update row_estimate {|r| try-int $r.row_estimate $nulls }
    | core-update comment {|r| nullify-val $r.comment $nulls }
  }
}

# Normalize raw `columns` introspection rows into their cached shape.
#
# Per row: replaces the SQL-standard textual `is_nullable` ("YES"/"NO", from
# information_schema) with a boolean `nullable` field, int-coerces `position` and
# the length/precision/scale numbers, turns a `default`/`comment` holding one of
# the dialect's NULL placeholders (`nulls`) into a real `null`, and appends a
# `display_type` by calling the injected `display_type` closure with the *cleaned*
# record (e.g. psql synthesizes `varchar(255)` from parts, mysql reads
# `column_type` straight from `udt_name`).
@category mole-sql
@example "textual is_nullable becomes a bool; display_type is injected" {
  let raw = [{schema: public, table: users, name: id, position: "1", data_type: integer, udt_name: int4, is_nullable: "NO", default: null, char_max_length: "", numeric_precision: "32", numeric_scale: "0", comment: "pk"}]
  sql normalize-columns $raw {|c| $c.data_type } [""] | first | get name nullable position display_type
} --result [id, false, 1, integer]
export def "normalize-columns" [
  rows: list<any>       # raw column rows using the common `columns` aliases
  display_type: closure # builds the friendly type string from a cleaned row: {|col: record| -> string }
  nulls: list<string>   # the dialect's NULL placeholder string(s)
]: nothing -> list<any> {
  $rows | each {|c|
    let nullable_raw = ($c | get -o is_nullable | default "")
    let nullable = (($nullable_raw | into string | str lowercase) in ["yes" "t" "true" "1"])
    let cleaned = $c
      | core-update position {|r| try-int $r.position $nulls }
      | core-update char_max_length {|r| try-int $r.char_max_length $nulls }
      | core-update numeric_precision {|r| try-int $r.numeric_precision $nulls }
      | core-update numeric_scale {|r| try-int $r.numeric_scale $nulls }
      | core-update default {|r| nullify-val $r.default $nulls }
      | core-update comment {|r| nullify-val $r.comment $nulls }
      | reject is_nullable
      | core-insert nullable $nullable
    $cleaned | core-insert display_type (do $display_type $cleaned)
  }
}

# Normalize raw `constraints` introspection rows into their cached shape.
#
# Splits the comma-joined `columns` and `ref_columns` strings the introspection
# SQL produces (via GROUP_CONCAT / string_agg) into real lists — an empty or
# placeholder value yields `[]` for `columns` and `null` for `ref_columns` — and
# nullifies the `ref_schema`/`ref_table` refs holding one of the dialect's NULL
# placeholders (`nulls`), i.e. non–foreign keys. Everything else passes through.
@category mole-sql
@example "column lists are split; placeholder refs become null" {
  sql normalize-constraints [{schema: public, table: t, name: pk, type: "PRIMARY KEY", columns: "a,b", ref_schema: "NULL", ref_table: "NULL", ref_columns: "NULL"}] ["NULL"]
  | first | get columns ref_table ref_columns
} --result [[a, b], null, null]
export def "normalize-constraints" [
  rows: list<any>       # raw constraint rows using the common `constraints` aliases
  nulls: list<string>   # the dialect's NULL placeholder string(s)
]: nothing -> list<any> {
  $rows | each {|c|
    $c
    | core-update columns {|r|
        let s = (nullify-val ($r.columns | default "") $nulls)
        if ($s | is-empty) { [] } else { $s | into string | split row "," }
      }
    | core-update ref_schema {|r| nullify-val $r.ref_schema $nulls }
    | core-update ref_table {|r| nullify-val $r.ref_table $nulls }
    | core-update ref_columns {|r|
        let s = (nullify-val ($r.ref_columns | default null) $nulls)
        if ($s | is-empty) { null } else { $s | into string | split row "," }
      }
  }
}

# Normalize and combine the three introspection sections into the cache body.
#
# Runs each section through its `normalize-*` helper — threading the injected
# `display_type` closure into the columns and the dialect's NULL placeholder(s)
# `nulls` into all three — and returns `{tables, columns, constraints}`. The
# plugin adds a `meta` record and writes the whole thing to the schema cache; the
# display, typing and completion helpers all read this shape back.
@category mole-sql
@example "assemble an (empty) cache body" {
  sql schema-body [] [] [] {|c| $c.data_type } [] | columns
} --result [tables, columns, constraints]
export def "schema-body" [
  tables: list<any>        # raw table rows (common `tables` aliases)
  columns: list<any>       # raw column rows (common `columns` aliases)
  constraints: list<any>   # raw constraint rows (common `constraints` aliases)
  display_type: closure    # friendly-type builder passed to `normalize-columns`: {|col: record| -> string }
  nulls: list<string>      # the dialect's NULL placeholder string(s), threaded to every normalize-*
]: nothing -> record {
  {
    tables: (normalize-tables $tables $nulls)
    columns: (normalize-columns $columns $display_type $nulls)
    constraints: (normalize-constraints $constraints $nulls)
  }
}

# ---- schema filtering (prune a cached `data` record to a table subset) --------

# Split a comma-separated flag value into a clean `list<string>` (trims, drops
# blanks); `null`/"" → `[]`. The list-valued schema filters (`--only a,b`) reach a
# verb as ONE comma-joined string — Nushell can't complete inside a `[...]` list
# literal — so this normalizes that wire form to the list the pure helpers want.
@category mole-sql
@example "split a comma list, trimming blanks and empties" {
  sql csv-split "users, public.orders ,"
} --result [users, public.orders]
@example "null or empty yields an empty list" {
  sql csv-split null
} --result []
export def "csv-split" [v: any]: nothing -> list<string> {
  $v | default "" | into string | split row "," | str trim | where {|x| $x | is-not-empty }
}

# Does `value` match `pattern`? Plain string equality, UNLESS the pattern carries a
# `*` wildcard — then `*` matches any run of characters and every other character
# (`.` included) stays literal. Case-sensitive, like the rest of the schema helpers.
def name-like [pattern: string, value: string]: nothing -> bool {
  if not ($pattern | str contains "*") { return ($value == $pattern) }
  let rx = "^" + ($pattern | split row "*" | each {|seg|
    $seg | str replace --all --regex '([.^$+?(){}\[\]|\\])' '\${1}'
  } | str join ".*") + "$"
  $value =~ $rx
}

# Does table `schema`.`name` match ANY of `patterns`? A pattern is either BARE
# (`users` / `tmp_*` — matches the NAME in any schema) or SCHEMA-QUALIFIED
# (`public.users` / `public.*` — matches schema AND name); either side may glob
# with `*`. An empty `patterns` list matches nothing.
def table-matches [schema: string, name: string, patterns: list<string>]: nothing -> bool {
  $patterns | any {|p|
    let parts = ($p | split row ".")
    if ($parts | length) >= 2 {
      (name-like ($parts | first) $schema) and (name-like ($parts | skip 1 | str join ".") $name)
    } else {
      name-like $p $name
    }
  }
}

# Prune a schema-cache record to a subset of its tables, kept self-contained.
#
# `--only` keeps ONLY matching tables (empty = keep all); `--exclude` then drops
# matching tables (applied AFTER `--only`, so on overlap exclude wins). Patterns are
# bare or `schema.`-qualified names, either side globbable with `*` (see
# `table-matches`). Besides removing the pruned tables' own rows from
# `tables`/`columns`/`constraints`, it also drops any FOREIGN KEY whose REFERENCED
# table was pruned away — otherwise that dangling relationship would make Mermaid
# auto-create a phantom entity for a table you deliberately excluded. Extra
# top-level keys (`meta`) survive, and with no filters `data` is returned untouched.
# This backs `schema --only/--exclude`, so a filtered `schema --full` feeds
# `mole-mermaid` a diagram of exactly the tables you want.
@category mole-sql
@example "keep only some tables — a now-dangling FK into a dropped table goes too" {
  let data = {
    tables: [{schema: public, name: users, type: "BASE TABLE", comment: null, row_estimate: 0}
             {schema: public, name: orders, type: "BASE TABLE", comment: null, row_estimate: 0}]
    columns: [{schema: public, table: orders, name: user_id, nullable: false}]
    constraints: [{schema: public, table: orders, name: fk, type: "FOREIGN KEY", columns: [user_id], ref_schema: public, ref_table: users, ref_columns: [id]}]
  }
  let r = (sql schema-filter $data --only [orders])
  [($r.tables | get name) ($r.constraints | length)]
} --result [[orders], 0]
@example "exclude housekeeping tables by glob" {
  let data = {tables: [{schema: public, name: users} {schema: public, name: audit_log}], columns: [], constraints: []}
  sql schema-filter $data --exclude ["*_log"] | get tables.name
} --result [users]
export def "schema-filter" [
  data: record                  # a schema-cache record ({tables, columns, constraints}; `meta` & extra keys kept)
  --only: list<string> = []     # keep ONLY tables matching these bare/qualified names or `*` globs
  --exclude: list<string> = []  # drop tables matching these (applied after --only)
]: nothing -> record {
  if ($only | is-empty) and ($exclude | is-empty) { return $data }
  let kept = ($data | get -o tables | default [] | where {|t|
    let inc = (($only | is-empty) or (table-matches $t.schema $t.name $only))
    let exc = (($exclude | is-not-empty) and (table-matches $t.schema $t.name $exclude))
    $inc and (not $exc)
  })
  let keys = ($kept | each {|t| $"($t.schema).($t.name)" })
  let in_set = {|sch, nam| $"($sch).($nam)" in $keys }
  let columns = ($data | get -o columns | default [] | where {|c| do $in_set $c.schema $c.table })
  let constraints = ($data | get -o constraints | default [] | where {|c|
    (do $in_set $c.schema $c.table) and (
      ($c.type != "FOREIGN KEY") or (($c | get -o ref_table) == null)
      or (do $in_set ($c | get -o ref_schema | default $c.schema) ($c | get -o ref_table))
    )
  })
  $data | merge {tables: $kept, columns: $columns, constraints: $constraints}
}

# ---- schema display (over a cached `data` record) -----------------------------

def str-has [haystack: any, needle: string]: nothing -> bool {
  ($haystack | default "" | into string | str lowercase) | str contains $needle
}

# Summarize a cached schema as one row per table.
#
# Each row is {schema, name, type, columns, pk, rows, comment}: `columns` is the
# column count, `pk` the primary-key column(s) comma-joined (empty when none),
# and `rows` the cached row estimate. This is the default `schema` view.
@category mole-sql
@example "one summary row per table, with column count and PK" {
  let data = {
    tables: [{schema: public, name: users, type: "BASE TABLE", comment: null, row_estimate: 5}]
    columns: [{schema: public, table: users, name: id} {schema: public, table: users, name: email}]
    constraints: [{schema: public, table: users, name: pk, type: "PRIMARY KEY", columns: [id]}]
  }
  sql schema-tables $data | first | get name columns pk rows
} --result [users, 2, id, 5]
export def "schema-tables" [
  data: record   # a schema-cache record ({tables, columns, constraints})
]: nothing -> list<any> {
  let columns = ($data | get -o columns | default [])
  let constraints = ($data | get -o constraints | default [])
  ($data | get -o tables | default []) | each {|t|
    let cols = ($columns | where schema == $t.schema and table == $t.name)
    let pk = ($constraints
      | where schema == $t.schema and table == $t.name and type == "PRIMARY KEY"
      | first | default null)
    {
      schema: $t.schema
      name: $t.name
      type: $t.type
      columns: ($cols | length)
      pk: (if $pk == null { "" } else { $pk.columns | str join ", " })
      rows: ($t | get -o row_estimate)
      comment: ($t | get -o comment)
    }
  }
}

# Full detail record for one cached table: its columns and its constraints.
#
# `table` is `"name"` or `"schema.name"`. Errors if no table matches; errors too
# if a bare name is ambiguous across schemas (the message names the candidates,
# use the qualified form). Returns {schema, name, type, comment, row_estimate,
# columns, constraints}. This is the `schema --table` view.
@category mole-sql
@example "detail record for one table" {
  let data = {
    tables: [{schema: public, name: users, type: "BASE TABLE", comment: null, row_estimate: 5}]
    columns: [{schema: public, table: users, name: id, position: 1, display_type: int4, nullable: false, default: null, comment: null}]
    constraints: [{schema: public, table: users, name: pk, type: "PRIMARY KEY", columns: [id], ref_schema: null, ref_table: null, ref_columns: null}]
  }
  sql schema-detail $data "users" | get name
} --result users
export def "schema-detail" [
  data: record    # a schema-cache record ({tables, columns, constraints})
  table: string   # target table, `"name"` or `"schema.name"`
]: nothing -> record {
  let tables = ($data | get -o tables | default [])
  let parts = ($table | split row ".")
  let hits = if ($parts | length) >= 2 {
    let sch = ($parts | first)
    let tbl = ($parts | skip 1 | str join ".")
    $tables | where schema == $sch and name == $tbl
  } else {
    $tables | where name == $table
  }
  if ($hits | is-empty) { error make {msg: $"table not found in cache: ($table)"} }
  if (($hits | length) > 1) {
    let names = ($hits | each {|t| $"($t.schema).($t.name)"} | str join ", ")
    error make {msg: $"ambiguous table name '($table)' — matched: ($names). Use schema.table form."}
  }
  let t = ($hits | first)
  # `core-select` is the aliased `select` builtin (see header gotcha) — a bare
  # `select` here would bind to the dialect plugin's `select` verb.
  let cols = ($data | get -o columns | default []
    | where schema == $t.schema and table == $t.name
    | core-select position name display_type nullable default comment)
  let cons = ($data | get -o constraints | default []
    | where schema == $t.schema and table == $t.name
    | core-select type name columns ref_schema ref_table ref_columns)
  {
    schema: $t.schema
    name: $t.name
    type: $t.type
    comment: ($t | get -o comment)
    row_estimate: ($t | get -o row_estimate)
    columns: $cols
    constraints: $cons
  }
}

# Case-insensitive search across cached table/column names and comments.
#
# Returns one hit row per match — {schema, table, column, kind, match} — where
# `column` is empty for table hits and `kind` records where the match landed:
# `table` / `table-comment` / `column` / `column-comment`. Table hits come first,
# then column hits. This is the `schema --find` view.
@category mole-sql
@example "match a column name, case-insensitively" {
  let data = {
    tables: [{schema: public, name: users, type: "BASE TABLE", comment: null, row_estimate: 5}]
    columns: [{schema: public, table: users, name: id, comment: "primary key"}]
    constraints: []
  }
  sql schema-find $data "ID" | where column == "id" | length
} --result 1
export def "schema-find" [
  data: record      # a schema-cache record ({tables, columns, constraints})
  pattern: string   # substring to search for (matched case-insensitively)
]: nothing -> list<any> {
  let p = ($pattern | str lowercase)
  let table_hits = ($data | get -o tables | default []
    | where {|t| (str-has $t.name $p) or (str-has ($t | get -o comment) $p) }
    | each {|t|
        let name_hit = (str-has $t.name $p)
        {
          schema: $t.schema
          table: $t.name
          column: ""
          kind: (if $name_hit { "table" } else { "table-comment" })
          match: (if $name_hit { $t.name } else { ($t | get -o comment | default "") })
        }
      })
  let column_hits = ($data | get -o columns | default []
    | where {|c| (str-has $c.name $p) or (str-has ($c | get -o comment) $p) }
    | each {|c|
        let name_hit = (str-has $c.name $p)
        {
          schema: $c.schema
          table: $c.table
          column: $c.name
          kind: (if $name_hit { "column" } else { "column-comment" })
          match: (if $name_hit { $c.name } else { ($c | get -o comment | default "") })
        }
      })
  $table_hits ++ $column_hits
}

# ---- completion helpers (pure; plugin shims load the cache & pass it in) ------

# Extract a flag's value from a raw completion-context command line.
#
# Tries each spelling in `names` (long and short), accepts `--flag value` or
# `--flag=value`, and when the flag appears more than once takes the last
# occurrence. Returns `null` when no spelling is present. Completers use this to
# recover the `--connection` / `--from` a user has already typed.
@category mole-sql
@example "read a flag the user already typed" {
  sql parse-flag "select --from public.users -c prod" ["--connection" "-c"]
} --result prod
@example "null when the flag is absent" {
  sql parse-flag "select 1" ["--connection" "-c"]
} --result null
export def "parse-flag" [
  ctx: string           # the completion context (the partial command line)
  names: list<string>   # flag spellings to try, e.g. ["--connection" "-c"]
]: nothing -> any {
  let pat = '(?:' + ($names | str join "|") + ')[\s=]+(?P<v>[^\s]+)'
  let m = ($ctx | parse --regex $pat)
  if ($m | is-empty) { null } else { $m | last | get v }
}

# The leading positional (target table) of a write verb's completion context.
#
# `update`/`delete` take their table as the FIRST positional (`update <table> …`,
# `delete <table> …`), not a `--from` flag, so their column completer recovers it
# from here — the token immediately after the verb name. `verbs` lists the leaf
# names to anchor on (so one completer can serve both). Returns null when that slot
# is missing or is itself a flag, letting the caller fall back (to `--from`, then to
# every table's columns) — which is exactly what a `select` context wants, since it
# carries no `update`/`delete` token.
@category mole-sql
@example "the table right after the verb" {
  sql lead-arg 'mole-psql update users "a = 1"' [update delete]
} --result "users"
@example "null when a flag takes the slot (caller falls back)" {
  sql lead-arg "mole-psql update -c prod " [update delete]
} --result null
export def "lead-arg" [
  ctx: string          # completion context (the partial command line up to the cursor)
  verbs: list<string>  # verb leaf names to anchor after, e.g. [update delete]
]: nothing -> any {
  let toks = ($ctx | split row --regex '\s+' | where {|t| $t | is-not-empty })
  let hits = ($toks | enumerate | where item in $verbs | get index)
  if ($hits | is-empty) { return null }
  let nxt = ($toks | get -o (($hits | first) + 1))
  if ($nxt | is-empty) or ($nxt | str starts-with "-") { null } else { $nxt }
}

# Fully-qualified `schema.name` table names from a cache record, for completion.
#
# Returns `[]` for an empty/absent cache, so a completer can call it blindly.
@category mole-sql
@example "qualified table names from a cache record" {
  sql complete-tables {tables: [{schema: public, name: users} {schema: public, name: orders}]}
} --result [public.users, public.orders]
@example "empty cache yields no completions" {
  sql complete-tables {}
} --result []
export def "complete-tables" [
  data: record   # a schema-cache record (reads its `tables`); {} is allowed
]: nothing -> list<string> {
  if ($data | is-empty) { return [] }
  ($data | get -o tables | default []) | each {|t| $"($t.schema).($t.name)" }
}

# Bare column names from a cache record, for a single-table SELECT projection.
# With `table`, that table's columns; without (e.g. columns typed before `--from`
# is on the line, so the table is unknown), the deduped names across all tables.
# Always UNQUALIFIED — this builder is single-table, so a `table.col` suggestion
# would be wrong (`SELECT orders.id FROM users` is invalid), never right.
@category mole-sql
@example "one table's columns" {
  sql complete-columns {columns: [{schema: public, table: users, name: id} {schema: public, table: users, name: email}]} "users"
} --result [id, email]
@example "no table given → deduped names across all tables" {
  sql complete-columns {columns: [{schema: public, table: users, name: id} {schema: public, table: orders, name: id}]}
} --result [id]
export def "complete-columns" [
  data: record     # a schema-cache record (reads its `columns`); {} is allowed
  table?: string   # restrict to this table (bare or `schema.name`); omit for all tables' columns
]: nothing -> list<string> {
  if ($data | is-empty) { return [] }
  if ($table | is-empty) {
    ($data | get -o columns | default []) | get name | uniq
  } else {
    (columns-for $data $table) | get name
  }
}
