# Registry of SQL drivers. Each entry declares everything that varies per-driver:
#   dangerous_keywords:  regex of statements that trigger the danger-prompt
#   exec:                closure {|ctx| ... } returning a `complete` record; ctx = {conf, base, query, functions}
#   parse:               closure {|stdout| ... } that turns raw stdout into a table
#   list_databases:      (optional) closure {|conf| ... } returning a `complete` record listing DBs
#   db_column:           (optional) column name to pluck from the parsed list_databases stdout
#   db_parser:           (optional) "tsv" | "csv" — how to parse list_databases stdout
export def registry [] {
  {
    mysql: {
      dangerous_keywords: '(?i)\b(delete|drop|truncate|update|insert|replace|create|alter|rename|grant|revoke|lock|unlock|analyze|optimize|repair|flush|kill|shutdown|load\s+data|outfile|dumpfile|call|execute|prepare|deallocate|set\s+global)\b'
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
      dangerous_keywords: '(?i)\b(delete|drop|truncate|update|insert|copy|create|alter|rename|grant|revoke|lock|analyze|vacuum|reindex|cluster|commit|rollback|savepoint|release|attach|detach|prepare|deallocate|execute|notify|listen|do\s+\$\$)\b'
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
  }
}
