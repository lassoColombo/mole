# mole-mermaid/mermaid.nu — the pure rendering CORE of the mole-mermaid module.
# Turns a mole SQL schema-cache record into a Mermaid diagram string.
# PRIVATE: mod.nu imports it (`use ./mermaid.nu`) and exposes exactly ONE public
# verb, `mole-mermaid er-schema`, built on `mermaid er-diagram`. Users never
# import this file directly — it stays a separate, pure file purely so the
# rendering logic is unit-testable and reusable internally.
#
# LAYERING: this file is PURE — it `use`s NOTHING (not mole core, not any
# submodule, not even mole-sql) and every command is data-in / data-out with no
# I/O, no clock, no env. It does NOT load the schema cache, does NOT know which
# connection is "current", and does NOT write files — mod.nu / the caller own
# that. It just receives the cached schema record and returns a string.
#
# INPUT — the schema-cache record `sql schema-body` produces (any mole SQL plugin
# writes it and returns it via `schema --full`):
#   {
#     meta?:       {...}          # ignored here (present in the full cache record)
#     tables:      [{schema, name, type, comment, row_estimate}, ...]
#     columns:     [{schema, table, name, position, display_type, nullable, comment, ...}, ...]
#     constraints: [{schema, table, name, type, columns, ref_schema, ref_table, ref_columns}, ...]
#   }
# `columns`/`ref_columns` on a constraint are already split into real lists, and
# `nullable` is already a bool — this file assumes that normalized shape and does
# no coercion of its own.
#
# OUTPUT — a Mermaid `erDiagram` string: one entity per table (its columns carry
# type, PK/FK/UK markers and comments) and one relationship per foreign key (the
# left cardinality is `||` when the FK is mandatory, `|o` when nullable). The
# result is a string — the caller pipes it to a file or a renderer.
#
# Mermaid's grammar is whitespace-sensitive: entity ids and attribute type/name
# tokens must be single words, so everything that flows into them is squeezed to
# [A-Za-z0-9_]. Free-text (comments, relationship labels) goes in quotes instead.

# Render a schema-cache record as a Mermaid `erDiagram`.
#
# Pipe the record a mole SQL plugin returns from `schema --full`
# ({tables, columns, constraints}; a `meta` key is tolerated and ignored).
# Entity ids are schema-qualified only when the schema spans more than one
# schema, so single-schema diagrams stay terse. Foreign keys whose referenced
# table lives outside the cached set still draw — Mermaid auto-creates the entity.
@category mole-mermaid
@example "an empty schema renders a placeholder erDiagram" {
  {tables: [], columns: [], constraints: []} | mermaid er-diagram
} --result "erDiagram\n    %% no tables in schema"
@example "one table with a primary-key column" {
  {
    tables: [{schema: public, name: users, type: "BASE TABLE", comment: null, row_estimate: 1}]
    columns: [{schema: public, table: users, name: id, position: 1, display_type: int4, nullable: false, comment: null}]
    constraints: [{schema: public, table: users, name: users_pk, type: "PRIMARY KEY", columns: [id], ref_schema: null, ref_table: null, ref_columns: null}]
  } | mermaid er-diagram
} --result "erDiagram\n    users {\n        int4 id PK\n    }"
export def "er-diagram" []: record -> string {
  let data = $in
  let tables = ($data | get -o tables | default [])
  let columns = ($data | get -o columns | default [])
  let constraints = ($data | get -o constraints | default [])

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

# ---- helpers (private) --------------------------------------------------------

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
