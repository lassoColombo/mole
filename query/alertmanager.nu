use "../cfg"
use "../helpers.nu"
use "../completers.nu"

# Fetch active alerts from an Alertmanager instance
export def main [
  --connection(-c): string@"completers alertmanager-connection"
  --host(-h): string
  --user(-u): string
  --password(-P): string
  --silenced
  --inhibited
  --unprocessed
] {
  if ($connection | is-not-empty) { cfg set $connection }
  let conf = helpers resolve-conf $connection
  let h = $host | default $conf.host
  http get $"($h)/api/v2/alerts?active=true&silenced=($silenced)&inhibited=($inhibited)&unprocessed=($unprocessed)"
}
