export use ./cfg.nu
use ./completers.nu
use ./drivers.nu

# Run a SQL query against a configured mysql/postgres connection.
export def sql [
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
  let conf = resolve-and-override $connection {
    driver: $driver, database: $database, port: $port,
    user: $user, host: $host, password: $password
  }
  assert-family $conf "sql"
  run $conf --query $query --file $file --yes=$yes
}

# Run a query against a configured mongo connection (via mongosh).
export def mongo [
  --query(-q): string                                    # Inline mongosh expression
  --file(-f): string@"completers queryfile"              # Path to a query file (relative to mole config dir)
  --connection(-c): string@"completers mongo-connection" # Named connection from ~/.config/mole.yml
  --database(-d): string@"completers mongo-database"     # Override the default database
  --port(-p): int                                        # Override the port
  --user(-u): string                                     # Override the user
  --host(-h): string                                     # Override the host
  --password(-P): string                                 # Override the password
  --auth-source(-a): string                              # Override the authSource (auth database)
  --tls                                                  # Enable TLS for this connection
  --tls-ca-file: path                                    # Path to the CA certificate file (implies TLS)
  --replica-set(-r): string                              # Override the replica set name
  --read-preference: string@"mongo-read-preference"      # primary | primaryPreferred | secondary | secondaryPreferred | nearest
  --yes(-y)                                              # Skip the dangerous-query confirmation prompt
] {
  let conf = resolve-and-override $connection {
    database: $database, port: $port, user: $user,
    host: $host, password: $password, authSource: $auth_source,
    tlsCAFile: $tls_ca_file, replicaSet: $replica_set, readPreference: $read_preference
  }
  let conf = if $tls or ($tls_ca_file | is-not-empty) { $conf | upsert tls true } else { $conf }
  assert-family $conf "mongo"
  run $conf --query $query --file $file --yes=$yes
}

def "mongo-read-preference" [] {
  ["primary" "primaryPreferred" "secondary" "secondaryPreferred" "nearest"]
}

# Open the query directory (or a specific query file) in the default editor.
export def edit [queryfile?: string@"completers queryfile"] {
  let d = cfg querydir
  let t = if ($queryfile | is-not-empty) {
    [$d $queryfile] | path join
  } else {
    $d
  }
  nu -c $"cd ($d); ($env.EDITOR) ($t)"
}

def resolve-and-override [connection: any, overrides: record] {
  if ($connection | is-not-empty) { cfg set $connection }
  resolve-conf $connection | apply-overrides $overrides
}

def assert-family [conf: record, family: string] {
  let driver_family = drivers registry | get $conf.driver | get -o family | default "sql"
  if $driver_family != $family {
    error make {msg: $"connection '($conf.name)' uses driver '($conf.driver)' which is not a ($family) driver"}
  }
}

def run [conf: record, --query: string, --file: string, --yes] {
  let functions = drivers registry | get $conf.driver
  let q = resolve-query $query $file (cfg querydir) ($functions | get -o query_suffix | default ".sql")
  if $q =~ $functions.dangerous_keywords and (not $yes) {
    let res = input $"(ansi yellow)This query might contain dangerous instructions. Execute? [y/N](ansi reset)" --numchar 1 --default 'n'
    if $res != y {
      print $"(ansi cyan)Aborting(ansi reset)"
      exit 0
    }
  }
  let result = do $functions.exec { conf: $conf, query: $q }
  if $result.exit_code != 0 { error make {msg: $"($result.stderr)\n($result.stdout)"} }
  try { do $functions.parse $result.stdout } catch { $result.stdout }
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

def resolve-query [query?: string, file?: string, basedir?: string, suffix: string = ".sql"] {
  if ($query | is-not-empty) { return $query }
  if ($file | is-not-empty) {
    let full = if ($basedir | is-not-empty) { [$basedir $file] | path join } else { $file }
    return (open -r $full)
  }
  let tmp = mktemp --suffix $suffix
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
