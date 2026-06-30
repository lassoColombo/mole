export use ./cfg.nu
export use ./schema.nu *
use ./types.nu
use ./complete.nu
use ./drivers.nu
use ./cache.nu

# Run a SQL query against a configured mysql/postgres connection.
export def "sql run" [
  --query(-q): string                                  # Inline SQL query
  --file(-f): string@"complete queryfile"            # Path to a query file (relative to mole config dir)
  --connection(-c): string@"complete sql-connection" # Named connection from ~/.config/mole.yml
  --driver(-D): string@"complete sql-driver"         # Override the driver (mysql or postgres)
  --database(-d): string@"complete sql-database"     # Override the database name
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

# Compose and run a SELECT query with completion-aware flags.
#
# Examples:
#   mole sql select --from customers
#   mole sql select id email --from customers --where "active" --limit 5
#   mole sql select --from orders --order-by "placed_at DESC" --limit 10
#
# Column tab-completion is context-aware: once --from <table> is set, columns
# are scoped to that table. Cached column types of --from are applied to the
# result automatically (booleans → bool, dates → datetime, ints → int, ...);
# pass --raw to skip the conversion.
export def "sql select" [
  ...columns: string@"complete sql-column"             # Columns to project (default: *)
  --from(-f): string@"complete schema-table"           # Source table
  --where(-w): string                                    # WHERE clause (without the WHERE keyword)
  --order-by(-o): string                                 # ORDER BY clause (without the ORDER BY keyword)
  --limit(-l): int                                       # LIMIT N
  --connection(-c): string@"complete sql-connection"   # Named connection (default: current)
  --raw(-R)                                              # Skip cached-type conversion of the result
  --print(-p)                                            # Print the assembled SQL instead of running it
] {
  if ($from | is-empty) { error make {msg: "--from <table> is required"} }
  let cols = if ($columns | is-empty) { "*" } else { $columns | str join ", " }
  let sql = [
    $"SELECT ($cols) FROM ($from)"
    (if ($where | is-not-empty) { $"WHERE ($where)" } else { null })
    (if ($order_by | is-not-empty) { $"ORDER BY ($order_by)" } else { null })
    (if $limit != null { $"LIMIT ($limit)" } else { null })
  ] | where {|x| $x != null } | str join " "
  if $print { return $sql }
  let conf = resolve-and-override $connection {}
  assert-family $conf "sql"
  let result = run $conf --query $sql
  if $raw { $result } else { $result | types apply $from --connection $conf.name }
}

# Run a query against a configured mongo connection (via mongosh).
export def mongo [
  --query(-q): string                                    # Inline mongosh expression
  --file(-f): string@"complete queryfile"              # Path to a query file (relative to mole config dir)
  --connection(-c): string@"complete mongo-connection" # Named connection from ~/.config/mole.yml
  --database(-d): string@"complete mongo-database"     # Override the default database
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

# Run commands against a configured redis/valkey connection (any RESP-
# compatible CLI). Multi-line --query / --file input is passed to the CLI on
# stdin, so each line runs as a separate command.
export def redis [
  --query(-q): string                                    # Inline command(s)
  --file(-f): string@"complete queryfile"              # Path to a query file (relative to mole config dir)
  --connection(-c): string@"complete redis-connection" # Named connection from ~/.config/mole.yml
  --driver(-D): string@"complete redis-driver"         # Override the driver (redis or valkey)
  --database(-d): string@"complete redis-database"     # Override the database index (0..N-1)
  --port(-p): int                                        # Override the port
  --user(-u): string                                     # Override the user (Redis ACL)
  --host(-h): string                                     # Override the host
  --password(-P): string                                 # Override the password
  --yes(-y)                                              # Skip the dangerous-query confirmation prompt
] {
  let conf = resolve-and-override $connection {
    driver: $driver, database: $database, port: $port,
    user: $user, host: $host, password: $password
  }
  assert-family $conf "redis"
  run $conf --query $query --file $file --yes=$yes
}

# Open the query directory (or a specific query file) in the default editor.
export def edit [queryfile?: string@"complete queryfile"] {
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
  let parsed = try { do $functions.parse $result.stdout } catch { $result.stdout }
  if (($functions | get -o family | default "sql") == "sql") {
    job spawn { try { cache refresh-if-stale $conf } catch { } } | ignore
  }
  $parsed
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
