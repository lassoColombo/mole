use "../cfg"
use "../helpers.nu"
use "../completers.nu"
use "../drivers.nu"

# Run a query against a SQL datasource (mysql, postgres)
export def main [
  --query(-q): string                                  # Inline SQL query
  --file(-f): string@"completers queryfile"            # Path to a query file (relative to mole config dir)
  --connection(-c): string@"completers sql-connection" # Named connection from ~/.config/mole.yml
  --driver(-D): string@"completers sql-driver"         # Override the driver (mysql or postgres)
  --database(-d): string@"completers sql-database"     # Override the database name
  --port(-p): int                                      # Override the port
  --user(-u): string                                   # Override the user
  --host(-h): string                                   # Override the host
  --password(-P): string                               # Override the password
  --yes(-y)                                            # Skip the dangerous-query confirmation prompt
] {
  let overrides = {
    driver: $driver, database: $database, port: $port,
    user: $user, host: $host, password: $password
  }
  let prep = helpers prepare --connection $connection --query $query --file $file --yes=$yes --overrides $overrides
  let sql_drivers = drivers family "sql"
  if $prep.conf.driver not-in $sql_drivers {
    error make {msg: $"'($prep.conf.driver)' is not a SQL driver. Use `mole mongo`, `mole redis`, etc."}
  }
  $prep | helpers run $prep.conf.driver
}
