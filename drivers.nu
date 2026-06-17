use ./ejson.nu

# Registry of database drivers. Each entry declares everything that varies per-driver:
#   dangerous_keywords:  regex of statements that trigger the danger-prompt
#   exec:                closure {|ctx| ... } returning a `complete` record; ctx = {conf, base, query, functions}
#   parse:               closure {|stdout| ... } that turns raw stdout into a table
#   list_databases:      (optional) closure {|conf| ... } returning a `list<string>` of database identifiers
#   query_suffix:        (optional) file extension for editor-temp queries (default ".sql")
def build-mongo-uri [conf: record, --no-db] {
  let auth = if (($conf | get -o user) | is-not-empty) {
    let pw = ($conf | get -o password | default "" | url encode)
    $"($conf.user):($pw)@"
  } else { "" }
  let db = if $no_db { "" } else { $conf | get -o database | default "" }
  let params = [
    {k: "authSource",     v: ($conf | get -o authSource)}
    {k: "tls",            v: (if ($conf | get -o tls | default false) { "true" } else { null })}
    {k: "tlsCAFile",      v: ($conf | get -o tlsCAFile)}
    {k: "replicaSet",     v: ($conf | get -o replicaSet)}
    {k: "readPreference", v: ($conf | get -o readPreference)}
  ] | where v != null and v != ""
  let qpart = if ($params | is-empty) { "" } else {
    "?" + ($params | each {|p| $"($p.k)=($p.v | url encode)"} | str join "&")
  }
  $"mongodb://($auth)($conf.host):($conf.port)/($db)($qpart)"
}

def redis-base-args [conf: record]: nothing -> list<string> {
  let user_args = if (($conf | get -o user) | is-not-empty) { ["--user" $conf.user] } else { [] }
  ["-h" $conf.host "-p" ($conf.port | into string) ...$user_args "--no-auth-warning"]
}

def redis-env [conf: record]: nothing -> record {
  if (($conf | get -o password) | is-not-empty) { { REDISCLI_AUTH: $conf.password } } else { {} }
}

# Builds a RESP-family driver entry parameterized by CLI binary (redis-cli,
# valkey-cli, keydb-cli, …). All RESP-compatible CLIs accept the same flags,
# danger surface, and database model, so the registry record only varies on
# which executable to spawn.
def make-resp-driver [bin: string]: nothing -> record {
  {
    family: "redis"
    # Mutating commands and admin verbs. Read-only commands (GET, KEYS, SCAN,
    # HGETALL, LRANGE, INFO, TYPE, TTL, …) are intentionally excluded.
    dangerous_keywords: '(?i)\b(set|setex|setnx|psetex|mset|msetnx|getset|getdel|append|del|unlink|flushdb|flushall|rename|renamenx|copy|move|migrate|expire|pexpire|expireat|pexpireat|persist|incr|decr|incrby|decrby|incrbyfloat|hset|hmset|hsetnx|hdel|hincrby|hincrbyfloat|lpush|lpushx|rpush|rpushx|lpop|rpop|lmpop|blpop|brpop|blmpop|brpoplpush|lset|lrem|ltrim|linsert|lmove|blmove|sadd|srem|spop|smove|sinterstore|sunionstore|sdiffstore|zadd|zrem|zincrby|zpopmin|zpopmax|bzpopmin|bzpopmax|zmpop|bzmpop|zrangestore|zunionstore|zinterstore|zdiffstore|bitop|setbit|setrange|restore|dump|xadd|xdel|xtrim|xsetid|xack|xclaim|xautoclaim|xgroup|geoadd|pfadd|pfmerge|debug|shutdown|bgsave|bgrewriteaof|save|reset|sync|psync|replicaof|slaveof|failover|eval|evalsha|fcall|fcall_ro)\b|(?i)\b(config|client|cluster|script|function|acl)\s+(set|kill|pause|unpause|no-evict|reset|failover|addslots|delslots|flushslots|forget|meet|replicate|setslot|resetstat|rewrite|flush|load|create|delete|restore|deluser|setuser|save)\b'
    exec: {|ctx|
      let db = $ctx.conf | get -o database
      let db_args = if ($db | is-not-empty) { ["-n" ($db | into string)] } else { [] }
      with-env (redis-env $ctx.conf) {
        $ctx.query | ^$bin ...(redis-base-args $ctx.conf) ...$db_args --json | complete
      }
    }
    parse: {|stdout|
      let lines = $stdout | lines | where {|l| ($l | str trim) != "" }
      if (($lines | length) == 0) {
        null
      } else if (($lines | length) == 1) {
        let only = $lines | first
        try { $only | from json } catch { $only }
      } else {
        $lines | each {|l| try { $l | from json } catch { $l } }
      }
    }
    list_databases: {|conf|
      let r = with-env (redis-env $conf) {
        ^$bin ...(redis-base-args $conf) --json CONFIG GET databases | complete
      }
      if $r.exit_code != 0 { [] } else {
        let parsed = try { $r.stdout | from json } catch { null }
        if $parsed == null { [] } else {
          let n = try { $parsed.databases | into int } catch { 0 }
          if $n <= 0 { [] } else { 0..($n - 1) | each {|i| $i | into string} }
        }
      }
    }
    query_suffix: ".redis"
  }
}

export def registry [] {
  {
    mysql: {
      family: "sql"
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
        let r = with-env { MYSQL_PWD: $conf.password } {
          "show databases;" | ^mysql -u $conf.user -h $conf.host -P $conf.port | complete
        }
        if $r.exit_code != 0 { [] } else { $r.stdout | from tsv | get Database }
      }
      schema_queries: {
        tables: (mysql-tables-sql)
        columns: (mysql-columns-sql)
        constraints: (mysql-constraints-sql)
      }
    }
    postgres: {
      family: "sql"
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
        let r = with-env { PGPASSWORD: $conf.password } {
          ^psql -h $conf.host -p $conf.port -U $conf.user --csv -q -c '\l' | complete
        }
        if $r.exit_code != 0 { [] } else { $r.stdout | from csv | get Name }
      }
      schema_queries: {
        tables: (postgres-tables-sql)
        columns: (postgres-columns-sql)
        constraints: (postgres-constraints-sql)
      }
    }
    mongo: {
      family: "mongo"
      dangerous_keywords: '(?i)(\binsert(One|Many)?\b|\bupdate(One|Many)?\b|\bdelete(One|Many)?\b|\breplaceOne\b|\bfindAndModify\b|\bbulkWrite\b|\bdrop(Database|Indexe?s?)?\b|\brenameCollection\b|\bcreate(Collection|Index|User|Role)\b|\$out\b|\$merge\b)'
      exec: {|ctx|
        let uri = (build-mongo-uri $ctx.conf)
        ^mongosh $uri --quiet --json=canonical --eval $ctx.query | complete
      }
      parse: {|stdout| $stdout | from json | ejson decode }
      list_databases: {|conf|
        let uri = (build-mongo-uri $conf --no-db)
        let r = ^mongosh $uri --quiet --json=relaxed --eval 'EJSON.stringify(db.adminCommand({listDatabases:1}).databases.map(d => d.name))' | complete
        if $r.exit_code != 0 { [] } else { $r.stdout | from json }
      }
      query_suffix: ".js"
    }
    redis:  (make-resp-driver "redis-cli")
    valkey: (make-resp-driver "valkey-cli")
  }
}

# ---- schema introspection SQL -------------------------------------------------
# Raw strings (r#'...'#) so the embedded single-quotes in SQL don't need
# escaping. Column aliases use the exact names cache.nu expects.

def postgres-tables-sql [] {
  r#'
    SELECT
      n.nspname AS "schema",
      c.relname AS "name",
      CASE c.relkind
        WHEN 'r' THEN 'BASE TABLE'
        WHEN 'v' THEN 'VIEW'
        WHEN 'm' THEN 'MATERIALIZED VIEW'
        WHEN 'f' THEN 'FOREIGN TABLE'
        WHEN 'p' THEN 'PARTITIONED TABLE'
      END AS "type",
      obj_description(c.oid) AS "comment",
      c.reltuples::bigint AS "row_estimate"
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relkind IN ('r','v','m','f','p')
      AND n.nspname NOT IN ('pg_catalog','information_schema')
    ORDER BY n.nspname, c.relname
  '#
}

def postgres-columns-sql [] {
  r#'
    SELECT
      c.table_schema AS "schema",
      c.table_name AS "table",
      c.column_name AS "name",
      c.ordinal_position AS "position",
      c.data_type AS "data_type",
      c.udt_name AS "udt_name",
      c.is_nullable AS "is_nullable",
      c.column_default AS "default",
      c.character_maximum_length AS "char_max_length",
      c.numeric_precision AS "numeric_precision",
      c.numeric_scale AS "numeric_scale",
      pgd.description AS "comment"
    FROM information_schema.columns c
    LEFT JOIN pg_catalog.pg_class pc
      ON pc.relname = c.table_name
     AND pc.relnamespace = (SELECT oid FROM pg_catalog.pg_namespace WHERE nspname = c.table_schema)
    LEFT JOIN pg_catalog.pg_description pgd
      ON pgd.objoid = pc.oid AND pgd.objsubid = c.ordinal_position
    WHERE c.table_schema NOT IN ('pg_catalog','information_schema')
    ORDER BY c.table_schema, c.table_name, c.ordinal_position
  '#
}

def postgres-constraints-sql [] {
  r#'
    SELECT
      n.nspname AS "schema",
      c.relname AS "table",
      con.conname AS "name",
      CASE con.contype
        WHEN 'p' THEN 'PRIMARY KEY'
        WHEN 'f' THEN 'FOREIGN KEY'
        WHEN 'u' THEN 'UNIQUE'
      END AS "type",
      (SELECT string_agg(att.attname, ',' ORDER BY u.ord)
         FROM unnest(con.conkey) WITH ORDINALITY AS u(attnum, ord)
         JOIN pg_attribute att ON att.attrelid = con.conrelid AND att.attnum = u.attnum) AS "columns",
      fn.nspname AS "ref_schema",
      fc.relname AS "ref_table",
      CASE WHEN con.contype = 'f' THEN
        (SELECT string_agg(fatt.attname, ',' ORDER BY u.ord)
           FROM unnest(con.confkey) WITH ORDINALITY AS u(attnum, ord)
           JOIN pg_attribute fatt ON fatt.attrelid = con.confrelid AND fatt.attnum = u.attnum)
      END AS "ref_columns"
    FROM pg_constraint con
    JOIN pg_class c ON c.oid = con.conrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    LEFT JOIN pg_class fc ON fc.oid = con.confrelid AND con.contype = 'f'
    LEFT JOIN pg_namespace fn ON fn.oid = fc.relnamespace
    WHERE con.contype IN ('p','f','u')
      AND n.nspname NOT IN ('pg_catalog','information_schema')
    ORDER BY n.nspname, c.relname, con.contype, con.conname
  '#
}

def mysql-tables-sql [] {
  r#'
    SELECT
      table_schema   AS `schema`,
      table_name     AS `name`,
      table_type     AS `type`,
      table_comment  AS `comment`,
      COALESCE(table_rows, 0) AS `row_estimate`
    FROM information_schema.tables
    WHERE table_schema = COALESCE(DATABASE(), table_schema)
      AND table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
    ORDER BY table_schema, table_name
  '#
}

def mysql-columns-sql [] {
  r#'
    SELECT
      table_schema  AS `schema`,
      table_name    AS `table`,
      column_name   AS `name`,
      ordinal_position AS `position`,
      data_type     AS `data_type`,
      column_type   AS `udt_name`,
      is_nullable   AS `is_nullable`,
      column_default AS `default`,
      character_maximum_length AS `char_max_length`,
      numeric_precision AS `numeric_precision`,
      numeric_scale AS `numeric_scale`,
      column_comment AS `comment`
    FROM information_schema.columns
    WHERE table_schema = COALESCE(DATABASE(), table_schema)
      AND table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
    ORDER BY table_schema, table_name, ordinal_position
  '#
}

def mysql-constraints-sql [] {
  r#'
    SELECT
      tc.table_schema  AS `schema`,
      tc.table_name    AS `table`,
      tc.constraint_name AS `name`,
      tc.constraint_type AS `type`,
      GROUP_CONCAT(kcu.column_name ORDER BY kcu.ordinal_position) AS `columns`,
      MAX(kcu.referenced_table_schema) AS `ref_schema`,
      MAX(kcu.referenced_table_name)   AS `ref_table`,
      CASE WHEN tc.constraint_type = 'FOREIGN KEY'
        THEN GROUP_CONCAT(kcu.referenced_column_name ORDER BY kcu.ordinal_position)
      END AS `ref_columns`
    FROM information_schema.table_constraints tc
    JOIN information_schema.key_column_usage kcu
      ON kcu.table_schema    = tc.table_schema
     AND kcu.table_name      = tc.table_name
     AND kcu.constraint_name = tc.constraint_name
    WHERE tc.constraint_type IN ('PRIMARY KEY','FOREIGN KEY','UNIQUE')
      AND tc.table_schema = COALESCE(DATABASE(), tc.table_schema)
      AND tc.table_schema NOT IN ('mysql','information_schema','performance_schema','sys')
    GROUP BY tc.table_schema, tc.table_name, tc.constraint_name, tc.constraint_type
    ORDER BY tc.table_schema, tc.table_name, FIELD(tc.constraint_type,'PRIMARY KEY','UNIQUE','FOREIGN KEY'), tc.constraint_name
  '#
}
