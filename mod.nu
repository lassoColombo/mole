export use ./cfg
use ./closures.nu

def queryfile-completer [] {
  glob --no-dir ([(cfg querydir) "**" "*"] | path join | into glob)
}

def connection-completer [] {
  cfg show | transpose database configuration | get database | uniq
}

def driver-completer [] {
  cfg show | transpose connection spec | get spec.driver | uniq
}


def database-completer [] {
  let c = cfg show -r -c | default {} | get -o conf
  if ($c | is-empty) { return [] } 

  let executor = closures executors | get $c.driver
  let formatter = closures database-formatters | get $c.driver
  let query = do (closures database-queries | get -o $c.driver | default {''})

  let result = do $executor $c $query
  if $result.exit_code != 0 {
    error make {msg: $"($result.stderr)\n($result.stdout)"}
  }
  try {
    $result.stdout | do $formatter
  } catch {
    $result.stdout
  }
}

export def edit [queryfile?: string@queryfile-completer] {
  let d = cfg querydir
  let t = $queryfile | default $d
  nu -c $"cd ($d); ($env.EDITOR) ($t)"
}

export def main [
  --query(-q): string
  --file(-f): string@queryfile-completer
  --connection(-c): string@connection-completer

  --driver(-D): string@driver-completer
  --database(-d): string@database-completer
  --port(-p): int
  --user(-u): string
  --host(-h): string
  --password(-P): string
] {
  if ($connection | is-not-empty) {
    cfg set $connection
  }
  if ($env.SQL_CURRENT_DATABASE? | is-empty) {
    error make {msg: "cannot run query: no connection set"}
  }
  mut q = ""
  if ($query | is-not-empty) {
    $q = $query
  } else if ($file | is-not-empty) {
    $q = open -r $file
  } else {
    let tmp = mktemp --suffix .sql
    nu -c $"($env.EDITOR) ($tmp)"
    $q = open -r $tmp
  }

  if $q =~ (closures danger-regex) {
    let res = input $"(ansi yellow) Tihs query might contain dangerous instructions. Do you want to execute it? [y/N](ansi reset)" --numchar 1 --default 'n'
    if $res != y {
      print $"(ansi cyan)Aborting(ansi reset)"
      return
    }
  }

  mut conf = {}
  if ($connection | is-not-empty) {
    $conf = cfg show -r | get -o $connection
    if ($conf | is-empty) {error make {msg: "unknown connection"}}
  } else {
    $conf = cfg show -r -c | get conf
  }

  let driver = $driver | default $conf.driver
  let executor = closures executors | get $driver
  let formatter = closures formatters | get $driver

  let result = do $executor $conf $q $database $port $user $host $password
  if $result.exit_code != 0 {
    error make {msg: $"($result.stderr)\n($result.stdout)"}
  }
  try {
    $result.stdout | do $formatter
  } catch {
    $result.stdout
  }
}

