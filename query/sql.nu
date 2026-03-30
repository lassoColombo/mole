use "../cfg"
use "../helpers.nu"
use "../completers.nu"

# Run a query against a SQL datasource (mysql, postgres)
export def main [
  --query(-q): string
  --file(-f): string@"completers queryfile"
  --connection(-c): string@"completers sql-connection"
  --driver(-D): string@"completers sql-driver"
  --database(-d): string@"completers sql-database"
  --port(-p): int
  --user(-u): string
  --host(-h): string
  --password(-P): string
] {
  if ($connection | is-not-empty) { cfg set $connection }
  let conf = helpers resolve-conf $connection
  let driver = $driver | default $conf.driver
  if $driver not-in [mysql postgres] {
    error make {msg: $"'($driver)' is not a SQL driver. Use `mole mongo`, `mole redis`, etc."}
  }
  let q = helpers resolve-query $query $file (cfg querydir)
  helpers danger-check $q
  let result = match $driver {
    "mysql" => (
      with-env { MYSQL_PWD: ($password | default $conf.password) } {
        $q | mysql -u ($user | default $conf.user) -h ($host | default $conf.host) -P ($port | default $conf.port) -D ($database | default $conf.database) | complete
      }
    )
    "postgres" => (
      with-env { PGPASSWORD: ($password | default $conf.password) } {
        psql -h ($host | default $conf.host) -p ($port | default $conf.port) -U ($user | default $conf.user) -d ($database | default $conf.database) --csv -q -c $q | complete
      }
    )
  }
  if $result.exit_code != 0 { error make {msg: $"($result.stderr)\n($result.stdout)"} }
  try {
    match $driver {
      "mysql" => ($result.stdout | from tsv)
      "postgres" => ($result.stdout | from csv)
    }
  } catch { $result.stdout }
}
