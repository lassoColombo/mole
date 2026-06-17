use ./cfg.nu
use ./cache.nu
use ./drivers.nu
use ./completers.nu

# Conversion tables: db-side type name → closure that converts one cell value
# to a native nushell value. Used internally by `mole sql select` to coerce
# query results using the cached column types of the source table.
#
# The closure is meant to be passed to `update <col>` so the whole column is
# converted in one go:
#   $rows | update <col> (mole types registry postgres | get "timestamp without time zone")

# Wraps a converter so null/empty/"NULL" pass through unchanged. The literal
# string "NULL" is what mysql renders for null cells in tab output; empty
# string is what psql --csv emits.
def null-or [convert: closure]: nothing -> closure {
  {||
    if $in == null {
      null
    } else if ($in | describe) == "string" and (($in | is-empty) or ($in == "NULL")) {
      null
    } else {
      do $convert $in
    }
  }
}

def postgres-registry [] {
  {
    "boolean":                     (null-or {|x| ($x | str downcase) in ["t" "true" "yes" "1"] })
    "smallint":                    (null-or {|x| $x | into int })
    "integer":                     (null-or {|x| $x | into int })
    "bigint":                      (null-or {|x| $x | into int })
    "real":                        (null-or {|x| $x | into float })
    "double precision":            (null-or {|x| $x | into float })
    "numeric":                     (null-or {|x| $x | into float })
    "date":                        (null-or {|x| $x | into datetime })
    "timestamp without time zone": (null-or {|x| $x | into datetime })
    "timestamp with time zone":    (null-or {|x| $x | into datetime })
    "json":                        (null-or {|x| $x | from json })
    "jsonb":                       (null-or {|x| $x | from json })
  }
}

def mysql-registry [] {
  {
    "tinyint":   (null-or {|x| $x | into int })
    "smallint":  (null-or {|x| $x | into int })
    "mediumint": (null-or {|x| $x | into int })
    "int":       (null-or {|x| $x | into int })
    "bigint":    (null-or {|x| $x | into int })
    "float":     (null-or {|x| $x | into float })
    "double":    (null-or {|x| $x | into float })
    "decimal":   (null-or {|x| $x | into float })
    "date":      (null-or {|x| $x | into datetime })
    "datetime":  (null-or {|x| $x | into datetime })
    "timestamp": (null-or {|x| $x | into datetime })
    "json":      (null-or {|x| $x | from json })
  }
}

# The full data_type → closure map for a given driver. Unknown drivers yield {}.
export def registry [driver: string@"completers sql-driver"]: nothing -> record {
  match $driver {
    "postgres" => (postgres-registry)
    "mysql" => (mysql-registry)
    _ => {}
  }
}

# Converter for a specific cached column record. Returns null if the column's
# data_type has no registered converter — the apply step then leaves the
# column as-is. mysql tinyint(1) is treated as boolean by convention.
export def column-converter [driver: string, col: record]: nothing -> any {
  if $driver == "mysql" and $col.data_type == "tinyint" and (($col | get -o display_type) == "tinyint(1)") {
    return (null-or {|x| ($x | into int) != 0 })
  }
  registry $driver | get -o $col.data_type
}

# Convert a piped table of rows using the cached column types of <table>.
# Columns absent from the result or whose db type has no registered converter
# are left untouched.
export def "apply" [
  table: string@"completers schema-table"        # Table whose types should be applied
  --connection(-c): string@"completers sql-connection"
]: any -> any {
  let rows = $in
  let conf = resolve-conf $connection
  let data = cache load $conf
  let cols = find-table-columns $data $table
  if ($cols | is-empty) {
    error make {msg: $"table not found in cache: ($table)"}
  }
  let result_cols = $rows | columns
  $cols
  | where name in $result_cols
  | reduce --fold $rows {|col, acc|
      let conv = column-converter $conf.driver $col
      if $conv == null { $acc } else { $acc | update $col.name $conv }
    }
}

def find-table-columns [data: record, table: string] {
  let parts = $table | split row "."
  if ($parts | length) >= 2 {
    let sch = $parts | first
    let tbl = $parts | skip 1 | str join "."
    $data.columns | where schema == $sch and table == $tbl
  } else {
    $data.columns | where table == $table
  }
}

def resolve-conf [name?: string]: nothing -> record {
  if ($name | is-not-empty) {
    let c = cfg show -r $name
    if ($c | is-empty) { error make {msg: $"unknown connection: ($name)"} }
    return $c
  }
  let c = cfg show -r -c
  if ($c | is-empty) { error make {msg: "no connection set — pass --connection or `mole cfg set`"} }
  $c
}
