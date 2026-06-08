use "../cfg"
use "../helpers.nu"
use "../completers.nu"

# Fetch active alerts from an Alertmanager instance
export def main [
  --connection(-c): string@"completers alertmanager-connection" # Named connection from ~/.config/mole.yml
  --host(-h): string                                            # Override the host (full URL)
  --user(-u): string                                            # Override the user
  --password(-P): string                                        # Override the password
  --silenced                                                    # Include silenced alerts
  --inhibited                                                   # Include inhibited alerts
  --unprocessed                                                 # Include unprocessed alerts
] {
  if ($connection | is-not-empty) { cfg set $connection }
  let conf = helpers resolve-conf $connection
  let h = $host | default $conf.host
  http get $"($h)/api/v2/alerts?active=true&silenced=($silenced)&inhibited=($inhibited)&unprocessed=($unprocessed)"
}
