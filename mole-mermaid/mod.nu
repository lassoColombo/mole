# mole-mermaid — a SECOND user-facing exception to mole's file-only library rule
# (the first is mole-sqls). The pure libs (mole-sql, mole-promql) are imported by
# their file (`use mole-sql/sql.nu` → `sql …`); THIS package ships a mod.nu so it
# loads as `use mole-mermaid`, scoping its commands under the `mole-mermaid`
# prefix. It exposes two verbs:
#   - `mole-mermaid er-schema` — renders a mole SQL schema-cache record to Mermaid
#     `erDiagram` TEXT (pure; see ./mermaid.nu).
#   - `mole-mermaid render`    — renders arbitrary Mermaid TEXT to an image via
#     Docker (impure I/O; lives here).
# They compose: `… | mole-mermaid er-schema | mole-mermaid render`.
#
# UNLIKE mole-sqls, this package is FULLY standalone: mod.nu imports NOTHING from
# mole core. The schema record `er-schema` renders arrives on the PIPELINE — any
# mole SQL plugin produces it via `schema --full` — so mole-mermaid never touches
# connections, drivers, or the cache itself, and composes with every SQL driver
# (mysql, psql, duckdb, trino, …) for free:
#
#   mole-mysql schema --full | mole-mermaid er-schema | save schema.mmd
#   mole-psql  schema --full | mole-mermaid er-schema
#
# The pure rendering lives in ./mermaid.nu and is imported PRIVATELY (`use
# ./mermaid.nu`, never `export use`), so its `mermaid er-diagram` command and
# helpers never leak into `use mole-mermaid` — the public surface stays `er-schema`
# and `render`.

use ./mermaid.nu

# Render a mole SQL schema-cache record as a Mermaid ER-diagram string.
#
# Pipe in the record a SQL plugin returns from `schema --full`
# ({meta?, tables, columns, constraints}). Produces a Mermaid entity-relationship
# diagram (`erDiagram`): one entity per table carrying its columns (type, PK/FK/UK
# markers and comments) and one relationship per foreign key (the left
# cardinality reflects whether the FK is mandatory). The result is a string —
# redirect or pipe it where you need it.
@category mole-mermaid
@example "render a connection's schema to a .mmd file" {
  mole-mysql schema --full | mole-mermaid er-schema | save schema.mmd
}
@example "render a Postgres connection's schema" {
  mole-psql schema --full -c my-pg | mole-mermaid er-schema
}
export def "er-schema" []: record -> string {
  $in | mermaid er-diagram
}

# Render Mermaid diagram text (from stdin) to an image and open it.
#
# Needs Docker; pulls minlag/mermaid-cli on first use. Pipe in ANY Mermaid source
# — the `erDiagram` string `er-schema` produces, or a hand-written flowchart /
# sequence / … diagram. Renders to SVG by default (--format svg|png|pdf) and
# opens the result, unless --no-open, which instead returns the output path.
#
#   mole-mysql schema --full | mole-mermaid er-schema | mole-mermaid render
#   "graph TD; A-->B; A-->C" | mole-mermaid render
#   open diagram.mmd | mole-mermaid render --format png
#   let f = ("erDiagram\n  A ||--o{ B : has" | mole-mermaid render --no-open)
@category mole-mermaid
@example "render a flowchart and return its path instead of opening it" {
  "graph TD; A-->B" | mole-mermaid render --no-open
}
export def "render" [
  --format(-f): string = "svg"   # output format: svg | png | pdf
  --no-open                      # don't open; return the output file path instead
]: string -> any {
  if ($format not-in ["svg" "png" "pdf"]) {
    error make {msg: $"render: unsupported --format '($format)' — use svg, png or pdf"}
  }
  let dir = (mktemp -d)
  $in | save -f ($dir | path join "diagram.mmd")
  ^docker run --rm -v $"($dir):/data" minlag/mermaid-cli -i /data/diagram.mmd -o $"/data/diagram.($format)"
  let out = ($dir | path join $"diagram.($format)")
  if not $no_open { start $out; return }
  return $out
}
