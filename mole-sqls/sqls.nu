# mole-sqls/sqls.nu — the pure translation CORE of the mole-sqls module. Turns mole
# connection records into the config the `sqls` SQL language server consumes
# (https://github.com/sqls-server/sqls). PRIVATE: mod.nu imports it (`use ./sqls.nu`)
# and exposes exactly ONE public verb, `mole-sqls cfg translate`, built on `sqls
# config`. Users never import this file directly — it stays a separate, pure file
# purely so the translation logic is unit-testable and reusable internally.
#
# LAYERING: this file is PURE — it `use`s NOTHING (not mole core, not any
# submodule) and every command is data-in / data-out with no I/O, no clock, no
# env. It does NOT read connections.yaml, does NOT know which connection is
# "current", and does NOT render YAML or write files — mod.nu owns all of that.
# It just receives records (from `conn list` / `conn resolve`, already tagged with
# `driver`), left in whatever order the caller chose (the FIRST connection is
# sqls's default), and returns data. Everything stateful stays in mod.nu.
#
# INPUT — a mole connection record, as `conn list`/`conn resolve` return it:
#   {driver, name, host, port, user, password, database?, sqls?: {...}}
# where `driver` is the connections.yaml section it was filed under. The optional
# `sqls` sub-record is the ENRICHMENT OVERLAY (see below).
#
# OUTPUT — one sqls `connections:` entry. sqls's full DBConfig schema (yaml tags,
# from sqls v0.2.47 internal/database/config.go) is:
#   alias           string             friendly name
#   driver          string             mysql|postgresql|sqlite3|mssql|h2|vertica|oracle|clickhouse
#   dataSourceName  string             full DSN; OVERRIDES the individual fields below
#   proto           string             tcp|udp|unix|http
#   user            string
#   passwd          string
#   host            string
#   port            int
#   path            string             unix socket path (with proto: unix)
#   dbName          string
#   params          map<string,string> driver options, e.g. {sslmode: disable} / {tls: skip-verify}
#   sshConfig       {host, port, user, passPhrase, privateKey}   SSH tunnel
# The top-level config is {lowercaseKeywords: bool, connections: [entry, ...]}.
#
# BASE MAPPING (mole field → sqls field): name→alias, driver→driver (via `drivers`),
# password→passwd, database→dbName, user/host verbatim, port coerced to an int, and
# proto defaults to "tcp". Only drivers sqls actually implements are translatable —
# `drivers` is the authoritative map. `config` silently DROPS connections of any
# other driver (duckdb, trino, …); `entry` ERRORS on them (an explicit
# single-record contract).
#
# ENRICHMENT OVERLAY: a mole connection's optional `sqls: {...}` sub-record is
# merged OVER the base entry (its sqls-native keys win). That is how extra sqls
# knobs template through without bloating mole's flat connection schema — e.g. add
# `sqls: {params: {sslmode: disable}}`, an `sqls: {sshConfig: {...}}` tunnel, or
# force `sqls: {dataSourceName: "..."}` / `sqls: {driver: "mysql8"}`.

# The mole-driver → sqls-driver name map. The single source of truth for which
# mole drivers sqls can talk to (its KEYS are the supported set) and what each is
# called in a sqls entry's `driver:` field. The KEY is a mole connections.yaml
# section name (a driver mole actually ships), the VALUE the sqls `driver:` string.
# MariaDB speaks the MySQL protocol, so its connections ride sqls's `mysql` driver.
# A mole driver sqls cannot talk to (duckdb, trino, the non-SQL ones) is simply not
# here; the other engines sqls implements (sqlite3, mssql, h2, vertica, oracle,
# clickhouse) have no mole driver and so no section to translate.
@category mole-sqls
@example "the supported driver map" { sqls drivers } --result {psql: "postgresql", mysql: "mysql", mariadb: "mysql"}
export def "drivers" []: nothing -> record {
  {
    psql: "postgresql"
    mysql: "mysql"
    mariadb: "mysql"
  }
}

# The sqls driver for a connection record, or null when sqls has none for its
# mole driver — the one lookup `entry` (which errors) and `config` (which drops)
# both build on.
def driver-for [c: record]: nothing -> any {
  drivers | get -o ($c | get -o driver | default "")
}

# Translate ONE mole connection record into one sqls `connections:` entry.
#
# Pipe a connection record (as `conn resolve`/`conn list` return: tagged with
# `driver`, plus host/port/user/password/database). Builds the base entry, then
# merges the connection's optional `sqls` enrichment overlay on top, then drops
# null-valued fields so the rendered YAML stays clean. Errors if the connection's
# driver is not one sqls supports (see `sqls drivers`).
@category mole-sqls
@example "a psql connection becomes a postgresql entry" {
  {driver: "psql", name: "prod", host: "db", port: 5432, user: "u", password: "p", database: "app"} | sqls entry
} --result {alias: "prod", driver: "postgresql", proto: "tcp", user: "u", passwd: "p", host: "db", port: 5432, dbName: "app"}
@example "the sqls overlay enriches and overrides the base" {
  {driver: "psql", name: "prod", host: "db", port: 5432, user: "u", password: "p", database: "app", sqls: {params: {sslmode: "disable"}}} | sqls entry | get params
} --result {sslmode: "disable"}
export def "entry" []: record -> record {
  let c = $in
  let sqls_driver = (driver-for $c)
  if ($sqls_driver | is-empty) {
    error make {msg: $"sqls has no driver for the '($c | get -o driver | default '')' connection '($c | get -o name | default '?')' — supported: (drivers | columns | str join ', ')"}
  }
  # sqls's `port` is a Go int: a YAML `port: "5432"` must not reach it as a string.
  let port = ($c | get -o port)
  {
    alias: ($c | get -o name)
    driver: $sqls_driver
    proto: "tcp"
    user: ($c | get -o user)
    passwd: ($c | get -o password)
    host: ($c | get -o host)
    port: (if $port == null { null } else { $port | into int })
    dbName: ($c | get -o database)
  }
  | merge ($c | get -o sqls | default {})
  | without-nulls
}

# Translate a LIST of mole connection records into a full sqls config record.
#
# Pipe the connections (e.g. `conn list`, or `[$current] ++ $others` to make one
# the default) — input ORDER is PRESERVED, and sqls treats the first entry as its
# default connection. Connections whose driver sqls can't talk to are dropped.
# Returns `{lowercaseKeywords, connections}`; the caller renders it with `to yaml`.
@category mole-sqls
@example "wrap connection records into a sqls config" {
  [{driver: "psql", name: "prod", host: "db", port: 5432, user: "u", password: "p", database: "app"}] | sqls config
} --result {lowercaseKeywords: true, connections: [{alias: "prod", driver: "postgresql", proto: "tcp", user: "u", passwd: "p", host: "db", port: 5432, dbName: "app"}]}
export def "config" [
  --lowercase-keywords = true   # sqls top-level `lowercaseKeywords` setting
]: list<any> -> record {
  let conns = $in
  {
    lowercaseKeywords: $lowercase_keywords
    connections: ($conns | where {|c| (driver-for $c) != null } | each {|c| $c | entry })
  }
}

# Drop null-valued fields from a record (keeps empty strings, empty maps, etc.).
# Private: keeps generated sqls entries free of `dbName: null` / `passwd: null`.
def without-nulls []: record -> record {
  $in
  | items {|k, v| {k: $k, v: $v} }
  | where v != null
  | reduce --fold {} {|it, acc| $acc | upsert $it.k $it.v }
}
