use ./cfg.nu
use ./cache.nu
use ./drivers.nu
use ./complete.nu

# Show the cached schema for a SQL connection.
#
# Without --table: a summary row per table (schema, name, type, n_columns,
# primary key, row_estimate, comment).
#
# With --table NAME: a detailed record { table, columns, constraints } for the
# matching table. NAME may be "table" or "schema.table"; the latter is required
# when the same name exists in multiple schemas.
#
# --refresh forces a cache rebuild before reading. --full returns the entire
# cache record {connection, database, driver, tables, columns, constraints}
# instead of the per-table summary.
export def "sql schema" [
  --connection(-c): string@"complete sql-connection"   # Named connection (default: current)
  --table(-t): string@"complete schema-table"          # Detail view for one table
  --find: string                                         # Find tables/columns whose name or comment matches (case-insensitive)
  --refresh(-r)                                          # Rebuild the cache before reading
  --full                                                 # Return the full cache record
] {
  let conf = resolve-conf $connection
  assert-family $conf "sql"
  if $refresh { cache refresh $conf }
  let data = cache load $conf
  if $full { return $data }
  if ($find | is-not-empty) {
    schema-find $data $find
  } else if ($table | is-not-empty) {
    schema-table-detail $data $table
  } else {
    schema-table-list $data
  }
}

# Dump the cached schema for a SQL connection in a serialization/diagram format.
#
# The only format supported today is `mermaid`, which renders a Mermaid
# entity-relationship diagram (`erDiagram`): one entity per table carrying its
# columns (type, PK/FK/UK markers and comments) and one relationship per foreign
# key (left cardinality reflects whether the FK is mandatory). The result is a
# string — pipe it to a file or a renderer:
#
#   mole sql dumpschema | save schema.mmd
#   mole sql dumpschema -c my-pg --format mermaid
#
# --refresh rebuilds the cache before dumping. Formats live in the
# `dump-formatters` registry below; adding one entry there is enough to expose
# it here and in the --format completer.
export def "sql dumpschema" [
  --connection(-c): string@"complete sql-connection"   # Named connection (default: current)
  --format(-F): string@dump-formats = "mermaid"          # Output format (default: mermaid)
  --refresh(-r)                                          # Rebuild the cache before dumping
]: nothing -> string {
  let conf = resolve-conf $connection
  assert-family $conf "sql"
  if $refresh { cache refresh $conf }
  let data = cache load $conf
  let fmt = dump-formatters | get -o $format
  if ($fmt | is-empty) {
    let supported = dump-formatters | columns | str join ", "
    error make {msg: $"unknown format '($format)'. Supported: ($supported)"}
  }
  do $fmt $data
}

# ---- connection helpers -------------------------------------------------------

def resolve-conf [name?: string]: nothing -> record {
  if ($name | is-not-empty) {
    let c = cfg show -r $name
    if ($c | is-empty) { error make {msg: $"unknown connection: ($name)"} }
    return $c
  }
  let c = cfg show -r -c
  if ($c | is-empty) { error make {msg: "no connection set — pass --connection or `mole cfg set`"} }
  $c
}

def assert-family [conf: record, family: string] {
  let driver_family = drivers registry | get $conf.driver | get -o family | default "sql"
  if $driver_family != $family {
    error make {msg: $"connection '($conf.name)' uses driver '($conf.driver)' which is not a ($family) driver"}
  }
}

# ---- `sql schema` views -------------------------------------------------------

def schema-find [data: record, pat: string]: nothing -> any {
  let p = $pat | str downcase
  let table_hits = $data.tables
    | where {|t| (matches $t.name $p) or (matches ($t.comment | default "") $p) }
    | each {|t|
        let name_hit = (matches $t.name $p)
        {
          schema: $t.schema
          table: $t.name
          column: ""
          kind: (if $name_hit { "table" } else { "table-comment" })
          match: (if $name_hit { $t.name } else { ($t.comment | default "") })
        }
      }
  let column_hits = $data.columns
    | where {|c| (matches $c.name $p) or (matches ($c.comment | default "") $p) }
    | each {|c|
        let name_hit = (matches $c.name $p)
        {
          schema: $c.schema
          table: $c.table
          column: $c.name
          kind: (if $name_hit { "column" } else { "column-comment" })
          match: (if $name_hit { $c.name } else { ($c.comment | default "") })
        }
      }
  $table_hits ++ $column_hits
}

def matches [haystack: string, needle: string]: nothing -> bool {
  $haystack | str downcase | str contains $needle
}

def schema-table-list [data: record]: nothing -> any {
  $data.tables | each {|t|
    let cols = $data.columns | where schema == $t.schema and table == $t.name
    let pk = $data.constraints
      | where schema == $t.schema and table == $t.name and type == "PRIMARY KEY"
      | first
      | default null
    {
      schema: $t.schema
      name: $t.name
      type: $t.type
      columns: ($cols | length)
      pk: (if $pk == null { "" } else { $pk.columns | str join ", " })
      rows: $t.row_estimate
      comment: $t.comment
    }
  }
}

def schema-table-detail [data: record, name: string]: nothing -> any {
  let parts = $name | split row "."
  let matches = if ($parts | length) >= 2 {
    let sch = $parts | first
    let tbl = $parts | skip 1 | str join "."
    $data.tables | where schema == $sch and name == $tbl
  } else {
    $data.tables | where name == $name
  }
  if ($matches | is-empty) {
    error make {msg: $"table not found in cache: ($name)"}
  }
  if (($matches | length) > 1) {
    let names = $matches | each {|t| $"($t.schema).($t.name)"} | str join ", "
    error make {msg: $"ambiguous table name '($name)' — matched: ($names). Use schema.table form."}
  }
  let t = $matches | first
  let cols = $data.columns
    | where schema == $t.schema and table == $t.name
    | select position name display_type nullable default comment
  let cons = $data.constraints
    | where schema == $t.schema and table == $t.name
    | select type name columns ref_schema ref_table ref_columns
  {
    schema: $t.schema
    name: $t.name
    type: $t.type
    comment: $t.comment
    row_estimate: $t.row_estimate
    columns: $cols
    constraints: $cons
  }
}

# ---- `sql dumpschema` formats -------------------------------------------------

# Registry of schema dump formats. Each value is a closure {|data| -> string }
# that renders the cached schema record {meta, tables, columns, constraints}.
# Add a format by adding one entry; the --format flag, its completer, and the
# dispatch in `sql dumpschema` all read from these keys.
def dump-formatters []: nothing -> record {
  {
    mermaid: {|data| schema-to-mermaid $data }
  }
}

# Completer + single source of truth for the `--format` choices.
def dump-formats []: nothing -> list<string> {
  dump-formatters | columns
}

# ---- mermaid ER diagram -------------------------------------------------------
# Mermaid's grammar is whitespace-sensitive: entity ids and attribute type/name
# tokens must be single words, so everything that flows into them is squeezed to
# [A-Za-z0-9_]. Free-text (comments, relationship labels) goes in quotes instead.

# Render the cached schema record as a Mermaid `erDiagram`.
def schema-to-mermaid [data: record]: nothing -> string {
  let tables = $data | get -o tables | default []
  let columns = $data | get -o columns | default []
  let constraints = $data | get -o constraints | default []

  if ($tables | is-empty) {
    return "erDiagram\n    %% no tables in schema"
  }

  # Qualify entity ids with their schema only when more than one schema is
  # present, so single-schema diagrams stay terse.
  let multi_schema = (($tables | get schema | uniq | length) > 1)

  let entities = $tables | each {|t|
    {schema: $t.schema, table: $t.name, id: (mermaid-entity-id $t.schema $t.name $multi_schema)}
  }

  let blocks = $entities | each {|e|
    let cols = $columns
      | where {|c| $c.schema == $e.schema and $c.table == $e.table }
      | sort-by position
    let attrs = $cols | each {|col|
      let keys = column-keys $constraints $e.schema $e.table $col.name
      let type = mermaid-type ($col | get -o display_type | default ($col | get -o data_type) | default "unknown")
      let cname = mermaid-ident $col.name
      let key_part = if ($keys | is-empty) { "" } else { " " + ($keys | str join ",") }
      let comment = mermaid-attr-comment ($col | get -o comment)
      $"        ($type) ($cname)($key_part)($comment)"
    }
    if ($attrs | is-empty) {
      $"    ($e.id) {}"
    } else {
      let body = $attrs | str join "\n"
      $"    ($e.id) {\n($body)\n    }"
    }
  }

  let rels = $constraints
    | where {|c| $c.type == "FOREIGN KEY" and (($c | get -o ref_table) != null) }
    | each {|c|
        let child_id = entity-id-for $entities $c.schema $c.table $multi_schema
        let parent_id = entity-id-for $entities ($c | get -o ref_schema | default $c.schema) ($c | get -o ref_table) $multi_schema
        let left = if (fk-mandatory $columns $c) { "||" } else { "|o" }
        let label = mermaid-rel-label ($c | get -o name)
        $"    ($parent_id) ($left)--o{ ($child_id) : ($label)"
      }

  ["erDiagram"] ++ $blocks ++ $rels | str join "\n"
}

# Squeeze an arbitrary string into a Mermaid-safe identifier token.
def mermaid-ident [s: string]: nothing -> string {
  let cleaned = $s
    | str replace --all --regex '[^A-Za-z0-9_]+' '_'
    | str trim --char '_'
  if ($cleaned | is-empty) { "_" } else { $cleaned }
}

# Entity id for a (schema, table) pair, schema-qualified only in multi-schema diagrams.
def mermaid-entity-id [schema: string, table: string, multi_schema: bool]: nothing -> string {
  let raw = if $multi_schema { $"($schema)_($table)" } else { $table }
  mermaid-ident $raw
}

# Resolve a (schema, table) to its entity id, falling back to a derived id for
# referenced tables that live outside the cached set (Mermaid auto-creates them).
def entity-id-for [entities: table, schema: any, table: string, multi_schema: bool]: nothing -> string {
  let hit = $entities | where {|e| $e.schema == $schema and $e.table == $table }
  if ($hit | is-not-empty) {
    $hit | first | get id
  } else {
    mermaid-entity-id ($schema | default "") $table $multi_schema
  }
}

def mermaid-type [t: string]: nothing -> string { mermaid-ident $t }

# The PK/FK/UK markers for a column, derived from the table's constraints.
def column-keys [constraints: table, schema: string, table: string, col: string]: nothing -> list<string> {
  let cons = $constraints | where {|c| $c.schema == $schema and $c.table == $table }
  [
    (if ($cons | any {|c| $c.type == "PRIMARY KEY" and ($col in $c.columns) }) { "PK" })
    (if ($cons | any {|c| $c.type == "FOREIGN KEY" and ($col in $c.columns) }) { "FK" })
    (if ($cons | any {|c| $c.type == "UNIQUE" and ($col in $c.columns) }) { "UK" })
  ] | compact
}

# A foreign key is mandatory (one-and-only-one parent) when every column that
# makes it up is non-nullable; nullable FK columns make the parent optional.
def fk-mandatory [columns: table, c: record]: nothing -> bool {
  let recs = $columns | where {|r| $r.schema == $c.schema and $r.table == $c.table and ($r.name in $c.columns) }
  if ($recs | is-empty) { return true }
  $recs | all {|r| not ($r.nullable | default false) }
}

# A quoted Mermaid attribute comment (leading space included), or "" when empty.
def mermaid-attr-comment [comment: any]: nothing -> string {
  let c = $comment | default "" | into string | str trim
  if ($c | is-empty) { return "" }
  let safe = $c | str replace --all --regex '\s+' ' ' | str replace --all '"' "'"
  $" \"($safe)\""
}

# A quoted Mermaid relationship label (the constraint name).
def mermaid-rel-label [name: any]: nothing -> string {
  let n = $name | default "" | into string | str replace --all '"' "'" | str trim
  if ($n | is-empty) { "\"FK\"" } else { $"\"($n)\"" }
}
