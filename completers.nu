use ./cfg.nu
use ./drivers.nu
use ./cache.nu

export def queryfile [] {
  let base = cfg querydir
  glob --no-dir ([$base "**" "*"] | path join | into glob)
  | each {|f| $f | str replace $"($base)/" "" }
}

def drivers-by-family [family: string] {
  drivers registry
  | items {|name, d| {name: $name, family: ($d | get -o family | default "sql")} }
  | where family == $family
  | get name
}

def connections-for-family [family: string] {
  let allowed = drivers-by-family $family
  let c = cfg show
  let mongo = $c.mongo | each {|x| $x | upsert driver "mongo" }
  $c.sql ++ $mongo | where driver in $allowed | get name
}

# Extract `--connection <name>` / `-c <name>` from the typed command line, if
# present. Completers receive the full line typed so far as `context`; we use
# it so a `-c <conn>` override resolves to that connection instead of the
# session default. Returns null when no flag was typed.
def connection-from-context [context: string] {
  let m = $context | parse --regex '(?:--connection|-c)[\s=]+(?P<v>[^\s]+)'
  if ($m | is-empty) { null } else { $m | first | get v }
}

# Resolve the effective SQL connection record for a completer. Uses an
# override (typed `-c <name>`) when present, else the session default.
def resolve-sql-conf [context: string] {
  let override = connection-from-context $context
  let conf = if ($override | is-empty) {
    cfg show -r -c
  } else {
    let all = cfg show
    let hit = $all.sql | where name == $override
    if ($hit | is-empty) { null } else { $hit | first }
  }
  if ($conf | is-empty) { return null }
  let drv = try { drivers registry | get $conf.driver } catch { return null }
  if (($drv | get -o family | default "sql") != "sql") { return null }
  { conf: $conf, driver: $drv }
}

def database-for-family [context: string, family: string] {
  let override = connection-from-context $context
  let c = if ($override | is-empty) {
    cfg show -r -c
  } else {
    cfg show $override -r
  }
  if ($c | is-empty) { return [] }
  let c = if ($c | get -o driver | is-empty) { $c | upsert driver "mongo" } else { $c }
  let d = try { drivers registry | get $c.driver } catch { return [] }
  if (($d | get -o family | default "sql") != $family) { return [] }
  if ($d.list_databases? | is-empty) { return [] }
  let result = do $d.list_databases $c
  if $result.exit_code != 0 { return [] }
  match $d.db_parser {
    "tsv" => ($result.stdout | from tsv | get $d.db_column)
    "csv" => ($result.stdout | from csv | get $d.db_column)
    "json" => (do {
      let parsed = ($result.stdout | from json)
      if (($d | get -o db_column) | is-empty) { $parsed } else { $parsed | get $d.db_column }
    })
    _ => []
  }
}

export def sql-driver [] { drivers-by-family "sql" }
export def sql-connection [] { connections-for-family "sql" }
export def sql-database [context: string] { database-for-family $context "sql" }

export def mongo-connection [] { connections-for-family "mongo" }
export def mongo-database [context: string] { database-for-family $context "mongo" }

# Tables in the cached schema for the effective SQL connection. Reads from
# the cache file only — no DB roundtrip — so it stays fast in the REPL.
# Honors a `-c <conn>` override typed on the command line.
export def schema-table [context: string] {
  let data = load-cache-for $context
  if ($data | is-empty) { return [] }
  $data.tables | each {|t| $"($t.schema).($t.name)" }
}

# Columns from the cached schema, filtered by --from / -f when present.
# Honors a `-c <conn>` override typed on the command line.
export def sql-column [context: string] {
  let data = load-cache-for $context
  if ($data | is-empty) { return [] }
  let m = $context | parse --regex '(?:--from|-f)[\s=]+(?P<t>[A-Za-z0-9_.]+)'
  if ($m | is-empty) {
    return ($data.columns | each {|c| $"($c.table).($c.name)" } | uniq)
  }
  let arg = $m | first | get t
  let parts = $arg | split row "."
  let cols = if ($parts | length) >= 2 {
    $data.columns | where schema == $parts.0 and table == ($parts | skip 1 | str join ".")
  } else {
    $data.columns | where table == $arg
  }
  $cols | get name
}

def load-cache-for [context: string] {
  let r = resolve-sql-conf $context
  if ($r | is-empty) { return null }
  let path = cache path-for $r.conf
  if not ($path | path exists) { return null }
  try { open $path } catch { null }
}
