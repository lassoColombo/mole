def connection-completer [] {
  show | transpose database configuration | get database | uniq
}

export def querydir [] {
  [$env.HOME .config moles] | path join
}

export def file [] {
  [$env.HOME .config moles.yml] | path join
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
    return {name: $name conf: $conf}
  }
  if ($db | is-not-empty) {
    return ($cfg | get -o $db | do $fmt)
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
  let dbname = if ($dbname | is-not-empty) {$dbname} else {
    show 
    | transpose database configuration 
    | sk --format {$in.database} --preview {$in.configuration}
    | get database
  }
  $env.SQL_CURRENT_DATABASE = $dbname
}
