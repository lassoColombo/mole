use ./cfg.nu
use ./drivers.nu

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

def database-for-family [family: string] {
  let c = cfg show -r -c
  if ($c | is-empty) { return [] }
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
export def sql-database [] { database-for-family "sql" }

export def mongo-connection [] { connections-for-family "mongo" }
export def mongo-database [] { database-for-family "mongo" }
