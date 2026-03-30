use "../cfg"
use "../helpers.nu"
use "../completers.nu"

# Run a command against a Redis datasource
export def main [
  --query(-q): string
  --file(-f): string@"completers queryfile"
  --connection(-c): string@"completers redis-connection"
  --database(-d): string
  --port(-p): int
  --user(-u): string
  --host(-h): string
  --password(-P): string
] {
  if ($connection | is-not-empty) { cfg set $connection }
  let conf = helpers resolve-conf $connection
  let q = helpers resolve-query $query $file (cfg querydir)
  helpers danger-check $q
  let s = $q | split row -r '\s+'
  let result = with-env { REDISCLI_AUTH: ($password | default $conf.password) } {
    redis-cli -h ($host | default $conf.host) -p ($port | default $conf.port) -n ($database | default $conf.database) --raw $s.0 ...($s | skip 1) | complete
  }
  if $result.exit_code != 0 { error make {msg: $"($result.stderr)\n($result.stdout)"} }
  try {
    $result.stdout | lines | each {|l|
      try { return ($l | into int) }
      try { return ($l | into float) }
      try { return ($l | from json) }
      $l
    }
  } catch { $result.stdout }
}
