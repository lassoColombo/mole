use std/assert
use std/testing *
use ../sqls.nu

# ---- drivers ------------------------------------------------------------------

@test
def "drivers maps every sqls-supported driver by cli name" [] {
  assert equal (sqls drivers) {
    psql: "postgresql", mysql: "mysql", sqlite3: "sqlite3", sqlcmd: "mssql",
    h2: "h2", vsql: "vertica", sqlplus: "oracle", clickhouse: "clickhouse"
  }
}

@test
def "entry translates a non-postgres/mysql driver" [] {
  let c = {driver: "sqlplus", name: "o", host: "h", port: 1521, user: "u", password: "p", database: "d"}
  assert equal (($c | sqls entry) | get driver) "oracle"
}

# ---- entry --------------------------------------------------------------------

@test
def "entry translates a psql connection" [] {
  let c = {driver: "psql", name: "prod", host: "db", port: 5432, user: "u", password: "p", database: "app"}
  assert equal ($c | sqls entry) {
    alias: "prod", driver: "postgresql", proto: "tcp",
    user: "u", passwd: "p", host: "db", port: 5432, dbName: "app"
  }
}

@test
def "entry translates a mysql connection" [] {
  let c = {driver: "mysql", name: "m", host: "h", port: 3306, user: "r", password: "s", database: "d"}
  assert equal (($c | sqls entry) | get driver) "mysql"
}

@test
def "entry drops a null database" [] {
  let c = {driver: "psql", name: "n", host: "h", port: 5432, user: "u", password: "p"}
  assert equal ("dbName" in ($c | sqls entry | columns)) false
}

@test
def "entry keeps an empty-string password" [] {
  let c = {driver: "psql", name: "n", host: "h", port: 5432, user: "u", password: "", database: "d"}
  assert equal (($c | sqls entry) | get passwd) ""
}

@test
def "entry errors on an unsupported driver" [] {
  assert error { {driver: "duckdb", name: "x"} | sqls entry }
}

@test
def "entry errors on a missing driver" [] {
  assert error { {name: "x"} | sqls entry }
}

# ---- enrichment overlay -------------------------------------------------------

@test
def "overlay adds params" [] {
  let c = {driver: "psql", name: "n", host: "h", port: 5432, user: "u", password: "p", database: "d", sqls: {params: {sslmode: "disable"}}}
  assert equal (($c | sqls entry) | get params) {sslmode: "disable"}
}

@test
def "overlay adds an ssh tunnel" [] {
  let ssh = {host: "bastion", port: 22, user: "j", privateKey: "/k"}
  let c = {driver: "psql", name: "n", host: "h", port: 5432, user: "u", password: "p", database: "d", sqls: {sshConfig: $ssh}}
  assert equal (($c | sqls entry) | get sshConfig) $ssh
}

@test
def "overlay overrides a base field" [] {
  let c = {driver: "psql", name: "n", host: "h", port: 5432, user: "u", password: "p", database: "d", sqls: {driver: "postgresql", dataSourceName: "postgres://x"}}
  assert equal (($c | sqls entry) | get dataSourceName) "postgres://x"
}

# ---- config -------------------------------------------------------------------

@test
def "config wraps entries with lowercaseKeywords true by default" [] {
  let out = [{driver: "psql", name: "a", host: "h", port: 5432, user: "u", password: "p", database: "d"}] | sqls config
  assert equal $out.lowercaseKeywords true
  assert equal ($out.connections | length) 1
  assert equal ($out.connections.0.alias) "a"
}

@test
def "config honors --lowercase-keywords false" [] {
  let out = [{driver: "psql", name: "a", host: "h", port: 5432, user: "u", password: "p", database: "d"}] | sqls config --lowercase-keywords false
  assert equal $out.lowercaseKeywords false
}

@test
def "config drops unsupported drivers and preserves order" [] {
  let conns = [
    {driver: "psql",   name: "a", host: "h", port: 5432, user: "u", password: "p", database: "d"}
    {driver: "duckdb", name: "b", host: "h", port: 0,    user: "u", password: "p", database: "d"}
    {driver: "mysql",  name: "c", host: "h", port: 3306, user: "u", password: "p", database: "d"}
  ]
  let aliases = ($conns | sqls config | get connections | get alias)
  assert equal $aliases ["a" "c"]
}

@test
def "config on an empty list yields no connections" [] {
  let out = [] | sqls config
  assert equal $out.connections []
}
