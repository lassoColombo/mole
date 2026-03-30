export use ./cfg
use ./helpers.nu

export def queryfile [] {
  let base = cfg querydir
  glob --no-dir ([$base "**" "*"] | path join | into glob)
  | each {|f| $f | str replace $"($base)/" "" }
}

def connection-completer-for [drivers: list<string>] {
  cfg show
  | transpose connection conf
  | where conf.driver in $drivers
  | get connection
}

export def sql-driver [] { [mysql postgres] }
export def sql-connection [] { connection-completer-for (sql-driver) }
export def mongo-connection [] { connection-completer-for [mongo] }
export def redis-connection [] { connection-completer-for [redis] }
export def alertmanager-connection [] { connection-completer-for [alertmanager] }
export def vlogs-connection [] { connection-completer-for [vlogs] }

export def sql-database [] {
  let c = cfg show -r -c | transpose name conf | first | get -o conf
  if ($c | is-empty) { return [] }
  let q = match $c.driver {
    "mysql" => "show databases;"
    "postgres" => "\\l"
    _ => { return [] }
  }
  let result = match $c.driver {
    "mysql" => (
      with-env { MYSQL_PWD: $c.password } {
        $q | mysql -u $c.user -h $c.host -P $c.port | complete
      }
    )
    "postgres" => (
      with-env { PGPASSWORD: $c.password } {
        psql -h $c.host -p $c.port -U $c.user --csv -q -c $q | complete
      }
    )
  }
  if $result.exit_code != 0 { return [] }
  match $c.driver {
    "mysql" => ($result.stdout | from tsv | get Database)
    "postgres" => ($result.stdout | from csv | get Name)
  }
}
