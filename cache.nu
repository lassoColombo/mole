use ./drivers.nu

# Per-(connection, database) schema cache. Each refresh runs the driver's
# `schema_queries` (tables, columns, constraints) and writes the result to
# ~/.cache/mole/<conn>__<db>.nuon. The file shape is:
#   { meta: {connection, database, driver, refreshed_at}, tables, columns, constraints }
# Lists are flat — the schema display joins them at the edge.

# Time-to-live for a cached schema before refresh-if-stale rebuilds it.
def cache-ttl []: nothing -> duration { 1day }

# Cache directory honoring $env.XDG_CACHE_HOME.
def cache-dir []: nothing -> string {
  let xdg = $env.XDG_CACHE_HOME? | default ""
  let base = if ($xdg | is-not-empty) { $xdg } else { [$nu.home-path .cache] | path join }
  [$base mole] | path join
}

# Absolute path to the cache file for a resolved connection record.
export def path-for [conf: record]: nothing -> string {
  let db = $conf | get -o database | default "_default"
  let safe = $"($conf.name)__($db)" | str replace --all --regex '[^A-Za-z0-9._-]' '_'
  [(cache-dir) $"($safe).nuon"] | path join
}

# Rebuild the cache for a connection. No-op for drivers without schema_queries
# (e.g. mongo).
export def refresh [conf: record]: nothing -> nothing {
  let driver = drivers registry | get -o $conf.driver
  if ($driver | is-empty) { return }
  let queries = $driver | get -o schema_queries
  if ($queries | is-empty) { return }

  # Run the three introspection queries in parallel — they're independent and
  # each spawns its own psql/mysql process, so par-each cuts wall-clock roughly
  # to the slowest single query instead of their sum.
  let sections = [tables columns constraints]
    | par-each {|k| {key: $k, rows: (fetch-section $conf $driver ($queries | get $k))} }
    | reduce -f {} {|it, acc| $acc | upsert $it.key $it.rows }

  let tables = $sections.tables | each {|r| post-process-table $r }
  let columns = $sections.columns | each {|r| post-process-column $r $conf.driver }
  let constraints = $sections.constraints | each {|r| post-process-constraint $r }

  let path = path-for $conf
  mkdir ($path | path dirname)
  {
    meta: {
      connection: $conf.name
      database: ($conf | get -o database | default "")
      driver: $conf.driver
      refreshed_at: (date now)
    }
    tables: $tables
    columns: $columns
    constraints: $constraints
  } | to nuon | save -f $path
}

# True if the cache is missing, unreadable, missing meta, or older than the TTL.
export def is-stale [conf: record]: nothing -> bool {
  let path = path-for $conf
  if not ($path | path exists) { return true }
  let data = try { open $path } catch { return true }
  let when = $data | get -o meta | get -o refreshed_at
  if $when == null { return true }
  ((date now) - $when) > (cache-ttl)
}

# Refresh only when the cache is stale.
export def refresh-if-stale [conf: record]: nothing -> nothing {
  if (is-stale $conf) { refresh $conf }
}

# Read the cached schema, rebuilding if missing or corrupt.
export def load [conf: record]: nothing -> record {
  let path = path-for $conf
  if not ($path | path exists) { refresh $conf }
  try { open $path } catch {
    refresh $conf
    open $path
  }
}

# Delete the cache file for a connection.
export def clear [conf: record]: nothing -> nothing {
  let path = path-for $conf
  if ($path | path exists) { rm $path }
}

def fetch-section [conf: record, driver: record, sql: string] {
  let result = do $driver.exec { conf: $conf, query: $sql }
  if $result.exit_code != 0 {
    error make {msg: $"schema fetch failed: ($result.stderr)\n($result.stdout)"}
  }
  do $driver.parse $result.stdout
}

# Empty cell or literal "NULL" (mysql renders nulls that way in tsv) → null.
def nullify [x: any]: nothing -> any {
  if ($x | is-empty) { return null }
  if ($x | describe) == "string" and $x == "NULL" { return null }
  $x
}

def try-int [x: any]: nothing -> any {
  let n = nullify $x
  if $n == null { return null }
  if ($n | describe) == "int" { return $n }
  try { $n | into int } catch { null }
}

def post-process-table [t: record]: nothing -> record {
  $t
  | update row_estimate {|r| try-int $r.row_estimate }
  | update comment {|r| nullify $r.comment }
}

def post-process-column [c: record, driver: string]: nothing -> record {
  let nullable_raw = $c.is_nullable | default ""
  let nullable = (($nullable_raw | into string | str downcase) in ["yes" "t" "true" "1"])
  let cleaned = $c
    | update position {|r| try-int $r.position }
    | update char_max_length {|r| try-int $r.char_max_length }
    | update numeric_precision {|r| try-int $r.numeric_precision }
    | update numeric_scale {|r| try-int $r.numeric_scale }
    | update default {|r| nullify $r.default }
    | update comment {|r| nullify $r.comment }
    | reject is_nullable
    | insert nullable $nullable
  $cleaned | insert display_type (display-type $cleaned $driver)
}

def post-process-constraint [c: record]: nothing -> record {
  $c
  | update columns {|r|
      let s = nullify ($r.columns | default "")
      if $s == null { [] } else { $s | into string | split row "," }
    }
  | update ref_schema {|r| nullify $r.ref_schema }
  | update ref_table {|r| nullify $r.ref_table }
  | update ref_columns {|r|
      let s = nullify ($r.ref_columns | default null)
      if $s == null { null } else { $s | into string | split row "," }
    }
}

# Render a friendly column type. mysql already gives us "varchar(255)" via
# column_type stashed in udt_name; for postgres we synthesize from the parts.
def display-type [c: record, driver: string]: nothing -> string {
  if $driver == "mysql" {
    let ct = $c | get -o udt_name
    if ($ct | is-not-empty) { return ($ct | into string) }
  }
  let base = $c.data_type | into string
  let l = $c | get -o char_max_length
  if $l != null { return $"($base)\(($l))" }
  let p = $c | get -o numeric_precision
  if $p != null and ($base in ["numeric" "decimal"]) {
    let s = $c | get -o numeric_scale | default 0
    return $"($base)\(($p),($s))"
  }
  $base
}
