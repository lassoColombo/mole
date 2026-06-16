use ./cfg.nu
use ./drivers.nu

export def queryfile [] {
  let base = cfg querydir
  glob --no-dir ([$base "**" "*"] | path join | into glob)
  | each {|f| $f | str replace $"($base)/" "" }
}

def connection-completer-for [drivers: list<string>] {
  cfg show | where driver in $drivers | get name
}

export def sql-driver [] { drivers registry | columns }
export def sql-connection [] { connection-completer-for (drivers registry | columns) }

export def sql-database [] {
  let c = cfg show -r -c
  if ($c | is-empty) { return [] }
  let d = try { drivers registry | get $c.driver } catch { return [] }
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
