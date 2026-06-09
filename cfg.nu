use ../picky

def connection-completer [] {
  show | get name
}

export def querydir [] {
  [$env.HOME .config mole] | path join
}

export def file [] {
  [$env.HOME .config mole.yml] | path join
}

# Drop the password field from a connection record. Returns the input unchanged
# when it's empty/null or when --raw is set by the caller.
def hide-password [raw: bool]: any -> any {
  let c = $in
  if ($c | is-empty) or $raw { return $c }
  $c | reject password
}

export def show [db?: string@connection-completer, --current(-c), --raw(-r)] {
  let cfg = open (file)
  if $current {
    let name = $env.SQL_CURRENT_DATABASE? | default ""
    return ($cfg | where name == $name | first | default null | hide-password $raw)
  }
  if ($db | is-not-empty) {
    return ($cfg | where name == $db | first | default null | hide-password $raw)
  }
  $cfg | each {|c| $c | hide-password $raw }
}

export def edit [] {
  nu -c $"($env.EDITOR) (file)"
}

export def --env set [
  dbname?: string@connection-completer
] {
  let dbname = if ($dbname | is-not-empty) { $dbname } else {
    show | picky --fuzzy --display name | get -o name
  }
  if ($dbname | is-not-empty) {
    $env.SQL_CURRENT_DATABASE = $dbname
  }
}

def translate-to-spec [] { ["sqls"] }

# Render the mole.yml connections as a config for an external tool.
export def translate-to [spec: string@translate-to-spec] {
  match $spec {
    "sqls" => (translate-sqls)
    _ => (error make {msg: $"unknown translate spec: ($spec)"})
  }
}

# sqls language-server config.yml — https://github.com/sqls-server/sqls
def translate-sqls [] {
  let driver_map = { postgres: "postgresql", mysql: "mysql" }
  let connections = open (file)
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
