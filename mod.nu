export use ./cfg.nu
use ./completers.nu
use ./drivers.nu

# Run a SQL query against a configured connection.
export def main [
  --query(-q): string                                  # Inline SQL query
  --file(-f): string@"completers queryfile"            # Path to a query file (relative to mole config dir)
  --connection(-c): string@"completers sql-connection" # Named connection from ~/.config/mole.yml
  --driver(-D): string@"completers sql-driver"         # Override the driver (mysql or postgres)
  --database(-d): string@"completers sql-database"     # Override the database name
  --port(-p): int                                      # Override the port
  --user(-u): string                                   # Override the user
  --host(-h): string                                   # Override the host
  --password(-P): string                               # Override the password
  --yes(-y)                                            # Skip the dangerous-query confirmation prompt
] {
  if ($connection | is-not-empty) { cfg set $connection }
  let base = resolve-conf $connection
  let conf = $base | apply-overrides {
    driver: $driver, database: $database, port: $port,
    user: $user, host: $host, password: $password
  }
  let functions = drivers registry | get $conf.driver
  let q = resolve-query $query $file (cfg querydir)
  if $q =~ $functions.dangerous_keywords and (not $yes) {
    let res = input $"(ansi yellow)This query might contain dangerous instructions. Execute? [y/N](ansi reset)" --numchar 1 --default 'n'
    if $res != y {
      print $"(ansi cyan)Aborting(ansi reset)"
      exit 0
    }
  }
  let result = do $functions.exec { conf: $conf, base: $base, query: $q }
  if $result.exit_code != 0 { error make {msg: $"($result.stderr)\n($result.stdout)"} }
  try { do $functions.parse $result.stdout } catch { $result.stdout }
}

# Open the query directory in the default editor
export def edit [queryfile?: string@"completers queryfile"] {
  let d = cfg querydir
  let t = if ($queryfile | is-not-empty) {
    [$d $queryfile] | path join
  } else {
    $d
  }
  nu -c $"cd ($d); ($env.EDITOR) ($t)"
}

def resolve-conf [connection?: string] {
  if ($connection | is-not-empty) {
    let conf = cfg show -r $connection
    if ($conf | is-empty) { error make {msg: $"unknown connection: ($connection)"} }
    return $conf
  }
  let current = cfg show -r -c
  if ($current | is-empty) {
    error make {msg: "cannot run query: no connection set. Use --connection or `mole cfg set`"}
  }
  $current
}

def resolve-query [query?: string, file?: string, basedir?: string] {
  if ($query | is-not-empty) { return $query }
  if ($file | is-not-empty) {
    let full = if ($basedir | is-not-empty) { [$basedir $file] | path join } else { $file }
    return (open -r $full)
  }
  let tmp = mktemp --suffix .sql
  nu -c $"($env.EDITOR) ($tmp)"
  open -r $tmp
}

def apply-overrides [overrides: record]: record -> record {
  let base = $in
  $overrides
  | items {|k, v| {key: $k, value: $v}}
  | where value != null
  | reduce --fold $base {|it, acc| $acc | upsert $it.key $it.value }
}
