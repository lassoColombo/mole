use "../cfg"
use "../helpers.nu"
use "../completers.nu"

# Run a LogsQL query against a VictoriaLogs datasource
export def main [
  --query(-q): string                                    # Inline LogsQL query
  --file(-f): string@"completers queryfile"              # Path to a query file (relative to mole config dir)
  --connection(-c): string@"completers vlogs-connection" # Named connection from ~/.config/mole.yml
  --host(-h): string                                     # Override the host (full URL)
  --user(-u): string                                     # Override the user
  --password(-P): string                                 # Override the password
  --yes(-y)                                              # Skip the dangerous-query confirmation prompt
] {
  let overrides = { host: $host, user: $user, password: $password }
  let prep = helpers prepare --connection $connection --query $query --file $file --yes=$yes --overrides $overrides
  $prep | helpers run "vlogs"
}
