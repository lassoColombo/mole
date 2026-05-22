use ./cfg

export def resolve-conf [connection?: string] {
  if ($connection | is-not-empty) {
    let conf = cfg show -r | get -o $connection
    if ($conf | is-empty) { error make {msg: $"unknown connection: ($connection)"} }
    return $conf
  }
  let current = cfg show -r -c | transpose name conf | first | get -o conf
  if ($current | is-empty) {
    error make {msg: "cannot run query: no connection set. Use --connection or `mole cfg set`"}
  }
  $current
}

export def resolve-query [query?: string, file?: string, basedir?: string] {
  if ($query | is-not-empty) { return $query }
  if ($file | is-not-empty) {
    let full = if ($basedir | is-not-empty) { [$basedir $file] | path join } else { $file }
    return (open -r $full)
  }
  let tmp = mktemp --suffix .sql
  nu -c $"($env.EDITOR) ($tmp)"
  open -r $tmp
}

export def danger-check [q: string, --yes(-y)] {
  let danger_regex = '(?i)\b(
  delete|drop|truncate|remove|erase|destroy|purge|
  update|insert|replace|merge|
  create|alter|rename|comment|
  grant|revoke|
  commit|rollback|savepoint|release|
  lock|unlock|
  analyze|vacuum|reindex|cluster|compact|
  attach|detach|
  call|exec|execute|execute\s+immediate|eval|evaluate|
  prepare|deallocate|
  kill|shutdown|restart|
  flush|flushall|flushdb|
  copy|load\s+data|outfile|dumpfile|
  xp_cmdshell|sp_executesql|
  system|sys\.|pg_|information_schema|
  db\.dropDatabase|db\.createCollection|db\.runCommand|db\.eval|
  collection\.|index\.drop|index\.rebuild|
  rmdir|unlink
  )\b'
  if $q =~ $danger_regex and (not $yes) {
    let res = input $"(ansi yellow)This query might contain dangerous instructions. Execute? [y/N](ansi reset)" --numchar 1 --default 'n'
    if $res != y {
      print $"(ansi cyan)Aborting(ansi reset)"
      exit 0
    }
  }
}
