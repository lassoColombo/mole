use "../cfg"
use "../helpers.nu"
use "../completers.nu"

# Run a command against a Redis datasource
export def main [
  --query(-q): string                                    # Inline Redis command
  --file(-f): string@"completers queryfile"              # Path to a query file (relative to mole config dir)
  --connection(-c): string@"completers redis-connection" # Named connection from ~/.config/mole.yml
  --database(-d): string                                 # Override the database index
  --port(-p): int                                        # Override the port
  --user(-u): string                                     # Override the user
  --host(-h): string                                     # Override the host
  --password(-P): string                                 # Override the password
  --yes(-y)                                              # Skip the dangerous-query confirmation prompt
] {
  let overrides = {
    database: $database, port: $port, user: $user, host: $host, password: $password
  }
  let prep = helpers prepare --connection $connection --query $query --file $file --yes=$yes --overrides $overrides
  $prep | helpers run "redis"
}
