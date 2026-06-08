use ./cfg
use ./drivers.nu

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

# Merge non-null fields from `overrides` into the input record (right-biased).
export def apply-overrides [overrides: record]: record -> record {
  let base = $in
  $overrides
  | items {|k, v| {key: $k, value: $v}}
  | where value != null
  | reduce --fold $base {|it, acc| $acc | upsert $it.key $it.value }
}

# Bundle the common per-query prelude: connection lookup, CLI-override merge, query resolution, danger check.
# Returns { conf, base, query } where `conf` is the merged config and `base` is the original (for fields like mongo authSource).
export def prepare [
  --connection(-c): string  # Named connection from mole.yml
  --query(-q): string       # Inline query string
  --file(-f): string        # Path to a query file
  --overrides: record = {}  # CLI flag values to merge over the named connection
  --yes(-y)                 # Skip the dangerous-query confirmation prompt
]: nothing -> record {
  if ($connection | is-not-empty) { cfg set $connection }
  let base = resolve-conf $connection
  let conf = $base | apply-overrides $overrides
  let q = resolve-query $query $file (cfg querydir)
  danger-check $q --yes=$yes
  { conf: $conf, base: $base, query: $q }
}

# Execute a prepared ctx ({conf, base, query}) against the given driver.
# Looks up the driver entry in the registry, runs its `exec`, then `parse`.
export def run [driver: string]: record -> any {
  let ctx = $in
  let d = drivers lookup $driver
  let result = do $d.exec $ctx
  if $result.exit_code != 0 { error make {msg: $"($result.stderr)\n($result.stdout)"} }
  try { do $d.parse $result.stdout } catch { $result.stdout }
}
