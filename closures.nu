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

    mysql: {|conf, query, database?, port?, user?, host?, password?|
      with-env {
        MYSQL_PWD: ($password | default $conf.password)
      } {
        $query | mysql -u ($user | default $conf.user) -h ($host | default $conf.host) -P ($port | default $conf.port) -D ($database | default $conf.database)
        | complete
      }
    }

    postgres: {|conf, query, database?, port?, user?, host?, password?|
      with-env {
        PGPASSWORD: ($password | default $conf.password)
      } {
        psql -h ($host | default $conf.host) -p ($port | default $conf.port) -U ($user | default $conf.user) -d ($database | default $conf.database) --csv -q -c $query 
        | complete
      }
    }

    vlogs: {|conf, query, database?, port?, user?, host?, password?|
      curl -k --user $"($user | default $conf.user):($password | default $conf.password)" -d $"query=($query)" ($host | default $conf.host) | complete
    }

    mongo: {|conf, query, database?, port?, user?, host?, password?|
      let uri = $"mongodb://($user | default $conf.user):($password | default $conf.password)@($host | default $conf.host):($port | default $conf.port)/($database | default $conf.database)?authSource=($conf.database)"

      let js = {query: $query} | format pattern "
      (() => {{
      const result = {query};
      if (result?.toArray) {{
      return EJSON.stringify(result.toArray(), null, 2);
      }}
      return EJSON.stringify(result, null, 2);
      }})()"

      mongosh $uri --quiet --eval $js
      | complete
    }

    redis: {|conf, query, database?, port?, user?, host?, password?|
      with-env {
        REDISCLI_AUTH: ($password | default $conf.password)
      } {
        let s = $query | split row -r '\s+'
        let command = $s.0
        let args = $s | skip
        redis-cli -h ($host | default $conf.host) -p ($port | default $conf.port) -n ($database | default $conf.database) --raw $command ...$args
        | complete
      }
    }

    alertmanager: {|conf, query, database?, port?, user?, host?, password?|
      http get $"($host | default $conf.host)/api/v2/alerts?active=true&silenced=true&inhibited=true&unprocessed=true"
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

    alertmanager: {
      $in | from json
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

    mysql: {$in | from tsv | get Database}

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
