use ./cache.nu
use ./drivers.nu

def connection-file [] {
  [$env.HOME .config mole connections.yaml] | path join
}


# Flat list of all connections with the `driver` field attached (mongo entries
# omit it in the file).
def connection-list [] {
  let raw = open (file)
  let sql = $raw | get -o sql | default []
  let mongo = ($raw | get -o mongo | default []) | each {|c| $c | upsert driver "mongo" }
  $sql ++ $mongo
}

def connection-completer [] {
  connection-list | get name
}

# Absolute path to the directory holding mole's saved query files.
export def querydir []: nothing -> string {
  [$env.HOME .config mole queries] | path join
}

# Absolute path to the connections config file.
export def file []: nothing -> string {
  connection-file
}

# Drop the password field from a connection record. Returns the input unchanged
# when it's empty/null or when --raw is set by the caller.
def hide-password [raw: bool]: any -> any {
  let c = $in
  if ($c | is-empty) or $raw { return $c }
  $c | reject password
}

# Show connections from mole.yml.
#
# With no arguments, returns a record `{sql: <table>, mongo: <table>}` so each
# section stays internally consistent (sections have different keys, so a
# flat list would be heterogeneous).
#
# With a name or `--current`, returns the single matching connection record,
# or null if not found. Passwords are stripped unless `--raw` is set.
export def show [
  db?: string@connection-completer   # Connection name to look up (returns a single record)
  --current(-c)                      # Return the connection currently selected via `cfg set`
  --raw(-r)                          # Keep the `password` field in the output
] {
  if $current {
    let name = $env.SQL_CURRENT_DATABASE? | default ""
    return (connection-list | where name == $name | first | default null | hide-password $raw)
  }
  if ($db | is-not-empty) {
    return (connection-list | where name == $db | first | default null | hide-password $raw)
  }
  let raw_yml = open (file)
  {
    sql: ($raw_yml | get -o sql | default [] | each {|c| $c | hide-password $raw })
    mongo: ($raw_yml | get -o mongo | default [] | each {|c| $c | hide-password $raw })
  }
}

# Open mole.yml in $env.EDITOR to edit connections by hand.
export def edit []: nothing -> nothing {
  nu -c $"($env.EDITOR) (file)"
}

# Select the active connection used by `mole sql run`/`mole mongo` when no
# `--connection` flag is passed. Sets `$env.SQL_CURRENT_DATABASE`.
# Without an argument, opens an interactive fuzzy picker.
export def --env set [
  dbname?: string@connection-completer   # Connection name; if omitted, pick interactively
] {
  let dbname = if ($dbname | is-not-empty) { $dbname } else {
    connection-list | input list --fuzzy --display name | get -o name
  }
  if ($dbname | is-not-empty) {
    $env.SQL_CURRENT_DATABASE = $dbname
    let conf = connection-list | where name == $dbname | first | default null
    if ($conf | is-not-empty) {
      let family = drivers registry | get -o $conf.driver | get -o family | default "sql"
      if $family == "sql" {
        job spawn { try { cache refresh-if-stale $conf } catch { } } | ignore
      }
    }
  }
}

def translate-to-spec [] { ["sqls"] }

# Render the mole.yml connections as a config for an external tool.
# Currently supported specs: `sqls` (sqls-server config.yml).
export def translate-to [
  spec: string@translate-to-spec   # Target format name
] {
  match $spec {
    "sqls" => (translate-sqls)
    _ => (error make {msg: $"unknown translate spec: ($spec)"})
  }
}

# sqls language-server config.yml — https://github.com/sqls-server/sqls
def translate-sqls [] {
  let driver_map = { postgres: "postgresql", mysql: "mysql" }
  let connections = connection-list
  | where driver in ($driver_map | columns)
  | each {|c|
    {
      alias: $c.name
      driver: ($driver_map | get $c.driver)
      proto: "tcp"
      user: $c.user
      passwd: $c.password
      host: $c.host
      port: $c.port
      dbName: ($c | get -o database)
    }
  }
  { lowercaseKeywords: true, connections: $connections }
}
