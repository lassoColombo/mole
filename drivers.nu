# Registry of database drivers. Each entry declares everything that varies per-driver:
#   dangerous_keywords:  regex of statements that trigger the danger-prompt
#   exec:                closure {|ctx| ... } returning a `complete` record; ctx = {conf, base, query, functions}
#   parse:               closure {|stdout| ... } that turns raw stdout into a table
#   list_databases:      (optional) closure {|conf| ... } returning a `complete` record listing DBs
#   db_column:           (optional) column name to pluck from the parsed list_databases stdout; null = stdout is already flat
#   db_parser:           (optional) "tsv" | "csv" | "json" — how to parse list_databases stdout
#   query_suffix:        (optional) file extension for editor-temp queries (default ".sql")
def build-mongo-uri [conf: record, --no-db] {
  let auth = if (($conf | get -o user) | is-not-empty) {
    let pw = ($conf | get -o password | default "" | url encode)
    $"($conf.user):($pw)@"
  } else { "" }
  let db = if $no_db { "" } else { $conf | get -o database | default "" }
  let qs = $conf | get -o authSource
  let qpart = if ($qs | is-not-empty) { $"?authSource=($qs)" } else { "" }
  $"mongodb://($auth)($conf.host):($conf.port)/($db)($qpart)"
}

export def registry [] {
  {
    mysql: {
      dangerous_keywords: '(?i)\b(delete|drop|truncate|update|insert|replace|create|alter|rename|grant|revoke|lock|unlock|analyze|optimize|repair|flush|kill|shutdown|load\s+data|outfile|dumpfile|call|execute|prepare|deallocate|set\s+global)\b'
      exec: {|ctx|
        let db = $ctx.conf | get -o database
        let db_args = if ($db | is-not-empty) { ["-D" $db] } else { [] }
        with-env { MYSQL_PWD: $ctx.conf.password } {
          $ctx.query | ^mysql -u $ctx.conf.user -h $ctx.conf.host -P $ctx.conf.port ...$db_args | complete
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
        let db = $ctx.conf | get -o database
        let db_args = if ($db | is-not-empty) { ["-d" $db] } else { [] }
        with-env { PGPASSWORD: $ctx.conf.password } {
          ^psql -h $ctx.conf.host -p $ctx.conf.port -U $ctx.conf.user ...$db_args --csv -q -c $ctx.query | complete
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
      dangerous_keywords: '(?i)(\binsert(One|Many)?\b|\bupdate(One|Many)?\b|\bdelete(One|Many)?\b|\breplaceOne\b|\bfindAndModify\b|\bbulkWrite\b|\bdrop(Database|Indexe?s?)?\b|\brenameCollection\b|\bcreate(Collection|Index|User|Role)\b|\$out\b|\$merge\b)'
      exec: {|ctx|
        let uri = (build-mongo-uri $ctx.conf)
        ^mongosh $uri --quiet --json=relaxed --eval $ctx.query | complete
      }
      parse: {|stdout| $stdout | from json }
      list_databases: {|conf|
        let uri = (build-mongo-uri $conf --no-db)
        ^mongosh $uri --quiet --json=relaxed --eval 'EJSON.stringify(db.adminCommand({listDatabases:1}).databases.map(d => d.name))' | complete
      }
      db_column: null
      db_parser: "json"
      query_suffix: ".js"
    }
  }
}
