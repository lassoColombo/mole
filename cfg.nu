use ../picky

def connection-completer [] {
  show | transpose database configuration | get database | uniq
}

export def querydir [] {
  [$env.HOME .config mole] | path join
}

export def file [] {
  [$env.HOME .config mole.yml] | path join
}

export def show [db?: string@connection-completer, --current(-c), --raw(-r)] {
  let fmt = {
    let c = $in
    if ($c | is-empty) or $raw { return $c }
    $c | upsert password "***"
  }
  let cfg = open (file)
  if $current {
    let name = $env.SQL_CURRENT_DATABASE? | default ""
    let conf = $cfg | get -o $name | do $fmt
    if ($conf | is-empty) {return {}} else {return {$name: $conf}}
  }
  if ($db | is-not-empty) {
    return {$db: ($cfg | get -o $db | do $fmt)}
  }
  $cfg
  | transpose connection conf
  | each {|c| $c | update conf ($c.conf | do $fmt)}
  | reduce --fold {} {|elt acc| $acc | merge {$elt.connection: $elt.conf} }
}

export def edit [] {
  nu -c $"($env.EDITOR) (file)"
}

export def --env set [
  dbname?: string@connection-completer
] {
  let dbname = if ($dbname | is-not-empty) { $dbname } else {
    show
    | transpose database configuration
    | picky --fuzzy --display database
    | get -o database
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
  | transpose alias conf
  | where conf.driver in ($driver_map | columns)
  | each {|c|
    {
      alias: $c.alias
      driver: ($driver_map | get $c.conf.driver)
      proto: "tcp"
      user: $c.conf.user
      passwd: $c.conf.password
      host: $c.conf.host
      port: $c.conf.port
      dbName: $c.conf.database
    }
  }
  { lowercaseKeywords: true, connections: $connections }
}
