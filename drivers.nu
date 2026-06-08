# Registry of backend drivers. Each entry declares:
#   family:          family/subcommand it belongs to (sql, mongo, redis, vlogs)
#   exec:            closure {|ctx| ... } returning a `complete` record; ctx = {conf, base, query}
#   parse:           closure {|stdout| ... } that turns raw stdout into structured data
#   list_databases:  (optional) closure {|conf| ... } returning a `complete` record listing DBs
#   db_column:       (optional) column name to pluck from the parsed list_databases stdout
#   db_parser:       (optional) "tsv" | "csv" — how to parse list_databases stdout
export def registry [] {
  {
    mysql: {
      family: "sql"
      exec: {|ctx|
        with-env { MYSQL_PWD: $ctx.conf.password } {
          $ctx.query | ^mysql -u $ctx.conf.user -h $ctx.conf.host -P $ctx.conf.port -D $ctx.conf.database | complete
        }
      }
      parse: {|stdout| $stdout | from tsv }
      list_databases: {|conf|
        with-env { MYSQL_PWD: $conf.password } {
          "show databases;" | ^mysql -u $conf.user -h $conf.host -P $conf.port | complete
        }
      }
      db_column: "Database"
      db_parser: "tsv"
    }
    postgres: {
      family: "sql"
      exec: {|ctx|
        with-env { PGPASSWORD: $ctx.conf.password } {
          ^psql -h $ctx.conf.host -p $ctx.conf.port -U $ctx.conf.user -d $ctx.conf.database --csv -q -c $ctx.query | complete
        }
      }
      parse: {|stdout| $stdout | from csv }
      list_databases: {|conf|
        with-env { PGPASSWORD: $conf.password } {
          ^psql -h $conf.host -p $conf.port -U $conf.user --csv -q -c '\l' | complete
        }
      }
      db_column: "Name"
      db_parser: "csv"
    }
    mongo: {
      family: "mongo"
      exec: {|ctx|
        let uri = $"mongodb://($ctx.conf.user):($ctx.conf.password)@($ctx.conf.host):($ctx.conf.port)/($ctx.conf.database)?authSource=($ctx.base.database)&socketTimeoutMS=0"
        let js = {query: $ctx.query} | format pattern "(() => {{
          const result = {query};
          if (result?.toArray) {{ return EJSON.stringify(result.toArray(), null, 2); }}
          return EJSON.stringify(result, null, 2);
        }})()"
        ^mongosh $uri --quiet --eval $js | complete
      }
      parse: {|stdout| $stdout | from json }
    }
    redis: {
      family: "redis"
      exec: {|ctx|
        let s = $ctx.query | split row -r '\s+'
        with-env { REDISCLI_AUTH: $ctx.conf.password } {
          ^redis-cli -h $ctx.conf.host -p $ctx.conf.port -n $ctx.conf.database --raw $s.0 ...($s | skip 1) | complete
        }
      }
      parse: {|stdout|
        $stdout | lines | each {|l|
          try { return ($l | into int) }
          try { return ($l | into float) }
          try { return ($l | from json) }
          $l
        }
      }
    }
    vlogs: {
      family: "vlogs"
      exec: {|ctx|
        ^curl -k -"($ctx.conf.user):($ctx.conf.password)" -d $"query=($ctx.query)" $ctx.conf.host | complete
      }
      parse: {|stdout|
        $stdout
        | from json -o
        | each {|l|
          $l
          | update _time ($l._time | into datetime)
          | update _stream ($l._stream | str trim --left --char '{' | str trim --right --char '}' | parse --regex '(?<label>[^=,]+)="(?<value>[^"]*)"')
        }
      }
    }
  }
}

# Driver names that belong to the given family.
export def family [name: string]: nothing -> list<string> {
  registry | items {|k, v| if $v.family == $name { $k } } | compact
}

# Look up one driver entry by name. Errors if missing.
export def lookup [name: string] {
  let r = registry
  $r | get $name
}
