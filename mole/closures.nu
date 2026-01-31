export def danger-regex [] {
  '(?i)\b(
  delete|
  drop|
  truncate|
  remove|
  flush|
  erase|
  update|
  insert|
  replace|
  kill|
  shutdown|
  restart|
  flushall|
  flushdb|
  rmdir|
  unlink|
  clear|
  destroy|
  purge|
  revoke|
  alter|
  detach|
  compact|
  rollback|
  exec|
  evaluate|
  call|
  execfile|
  db.dropDatabase|
  db.createCollection|
  db.runCommand|
  db.eval|
  system\.|
  collection\.|
  index\.drop|
  index\.rebuild
  )\b'
}

export def executors [] {
  {

    mysql: {|conf, query, database?, port?, user?, host?|
      with-env {
        MYSQL_PWD: $conf.password
      } {
        $query | mysql -u ($user | default $conf.user) -h ($host | default $conf.host) -P ($port | default $conf.port) -D ($database | default $conf.database)
        | complete

      }
    }

    postgres: {|conf, query, database?, port?, user?, host?|
      with-env {
        PGPASSWORD: $conf.password
      } {
        psql -h ($host | default $conf.host) -p ($port | default $conf.port) -U ($user | default $conf.user) -d ($database | default $conf.database) --csv -q -c $query 
        | complete
      }
    }

    vlogs: {|conf, query, database?, port?, user?, host?|
      curl -k --user $"($conf.user):($conf.password)" -d $"query=($query)" ($host | default $conf.host) | complete
    }

    mongo: {|conf, query, database?, port?, user?, host?|
      | mongosh $"mongodb://($user | default $conf.user):($conf.password)@($host | default $conf.host):($port | default $conf.port)/($database | default $conf.database)?authSource=($conf.database)" --quiet --eval (
        {query: $query} | format pattern '
        EJSON.stringify(
          {query},
          null,
          2
        )
        '
      )
      | complete
    }

    redis: {|conf, query, database?, port?, user?, host?|
      with-env {
        REDISCLI_AUTH: $conf.password
      } {
        let s = $query | split row -r '\s+'
        let command = $s.0
        let args = $s | skip
        redis-cli -h ($host | default $conf.host) -p ($port | default $conf.port) -n ($database | default $conf.database) --raw $command ...$args
        | complete
      }
    }

  }
}

export def formatters [] {
  {

    mysql: {
      $in | from tsv 
    }

    postgres: {
      $in | from csv
    }

    vlogs: {
      $in
      | from json -o
      | each {|l|
        | update _time ($l._time | into datetime) 
        | update _stream ($l._stream | str trim --left --char '{' | str trim --right --char '}' | parse --regex '(?<label>[^=,]+)="(?<value>[^"]*)"') 
        # | update _msg ($l._msg | from json)
      }
    }

    mongo: {
      $in | from json
    }

    redis: {
      $in
      | lines
      | each {|l|
        try { return ($l | into int) } 
        try { return ($l | into float) } 
        try { return ($l | to json) }
        return $l
      }

    }
  }
}

export def database-formatters [] {
  {

    mysql: {$in | lines}

    postgres: {$in | from csv | get Name}

    vlogs: {$in}

    mongo: {$in | from json}

    redis: {
      let n = $in | find --regex 'db\d' | length
      0..($n - 1)
    }
  }
}


export def database-queries [] {
  {

    mysql: {"show databases;"}

    postgres: {"\\dt"}

    vlogs: {$in}

    mongo: {"db.adminCommand({ listDatabases: 1 }).databases.map(d => d.name)"}

    redis: {'info'}
  }
}
