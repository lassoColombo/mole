use "../cfg"
use "../helpers.nu"
use "../completers.nu"

# Run a LogsQL query against a VictoriaLogs datasource
export def main [
  --query(-q): string
  --file(-f): string@"completers queryfile"
  --connection(-c): string@"completers vlogs-connection"
  --host(-h): string
  --user(-u): string
  --password(-P): string
] {
  if ($connection | is-not-empty) { cfg set $connection }
  let conf = helpers resolve-conf $connection
  let q = helpers resolve-query $query $file (cfg querydir)
  helpers danger-check $q
  let result = curl -k -"($user | default $conf.user):($password | default $conf.password)" -d $"query=($q)" ($host | default $conf.host) | complete
  if $result.exit_code != 0 { error make {msg: $"($result.stderr)\n($result.stdout)"} }
  try {
    $result.stdout
    | from json -o
    | each {|l|
      $l
      | update _time ($l._time | into datetime)
      | update _stream ($l._stream | str trim --left --char '{' | str trim --right --char '}' | parse --regex '(?<label>[^=,]+)="(?<value>[^"]*)"')
    }
  } catch { $result.stdout }
}
