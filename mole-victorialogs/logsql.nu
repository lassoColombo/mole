# mole-victorialogs/logsql — PURE response-shaping helpers for the VictoriaLogs
# LogsQL HTTP API. Data-in / data-out: NO I/O and NO clock. These turn the
# various query, stats, hits and enumeration payloads the client returns into
# typed Nushell rows, and own the time/duration formatting VictoriaLogs wants.
#
# LAYERING: mod.nu imports this PRIVATELY (`use ./logsql.nu`) and the tests
# import it directly; nothing here is re-exported into `use mole-victorialogs`.
# Keeping the transforms pure is what makes them unit-testable (see
# tests/test_logsql.nu).
#
# VictoriaLogs stores every field as a string, so `/query` rows arrive with all
# values as strings; these helpers own the `_time` coercion. The Prometheus-shaped
# stats endpoints encode sample values as strings and instant timestamps as Unix
# seconds, while `/hits` timestamps are RFC3339 strings — both are handled here.

# ---- scalar coercions ---------------------------------------------------------

# A stats sample-value string → a real number. `NaN` becomes null (Nushell has no
# NaN literal); a non-string passes through untouched, and anything `into float`
# can't parse is kept as-is.
@category mole-victorialogs
@example "a numeric string becomes a float" { logsql num "3.14" } --result 3.14
@example "NaN becomes null" { logsql num "NaN" } --result null
export def "num" [v: any]: nothing -> any {
  if ($v | describe) != "string" { return $v }
  if $v == "NaN" { return null }
  try { $v | into float } catch { $v }
}

# A Unix timestamp (int/float seconds) → datetime. Used by the Prometheus-shaped
# stats endpoints, whose timestamps are epoch seconds.
@category mole-victorialogs
@example "epoch seconds to datetime" { logsql epoch 0 } --result 1970-01-01T00:00:00Z
@example "epoch seconds to datetime" { logsql epoch 1704067200 } --result 2024-01-01T00:00:00Z
export def "epoch" [ts: any]: nothing -> datetime { 1970-01-01T00:00:00Z + (($ts | into float) * 1sec) }

# An RFC3339 string → datetime. VictoriaLogs `_time` and `/hits` timestamps are
# RFC3339 strings; a value `into datetime` can't parse is kept as-is (so a query
# row whose `_time` is malformed still round-trips).
@category mole-victorialogs
@example "an RFC3339 string to datetime" { logsql rfc3339 "2024-01-01T00:00:00Z" } --result 2024-01-01T00:00:00Z
export def "rfc3339" [s: any]: nothing -> any {
  try { $s | into datetime } catch { $s }
}

# A datetime → the RFC3339 (UTC) string VictoriaLogs wants for start/end. Null
# passes through as null (so an unset flag stays omitted on the wire).
@category mole-victorialogs
@example "datetime to an RFC3339 UTC string" { logsql vl-time 2024-01-01T00:00:00Z } --result "2024-01-01T00:00:00.000000000Z"
@example "null stays null" { logsql vl-time null } --result null
export def "vl-time" [dt: any]: nothing -> any {
  if ($dt | is-empty) { null } else { $dt | date to-timezone UTC | format date "%Y-%m-%dT%H:%M:%S.%fZ" }
}

# A duration → the VictoriaLogs step string (integer seconds, e.g. `3600s`).
@category mole-victorialogs
@example "duration to step string" { logsql step 1hr } --result "3600s"
@example "null stays null" { logsql step null } --result null
export def "step" [d: any]: nothing -> any {
  if ($d | is-empty) { null } else { $"(($d / 1sec) | into int)s" }
}

# ---- query (JSONL) ------------------------------------------------------------

# A JSON-lines body → a table of records, one row per non-blank line. Every value
# is the raw string VictoriaLogs returned; `coerce-time` does the `_time` typing.
@category mole-victorialogs
@example "two log lines to rows" {
  logsql jsonl "{\"_time\":\"2024-01-01T00:00:00Z\",\"_msg\":\"a\"}\n{\"_time\":\"2024-01-01T00:00:01Z\",\"_msg\":\"b\"}"
} --result [{_time: "2024-01-01T00:00:00Z", _msg: a}, {_time: "2024-01-01T00:00:01Z", _msg: b}]
export def "jsonl" [body: string]: nothing -> table {
  $body | lines | where {|l| ($l | str trim) != "" } | each {|l| $l | from json }
}

# Coerce the `_time` column of a query result to datetime, leaving every other
# field as the string VictoriaLogs returned. A row missing `_time` is untouched.
@category mole-victorialogs
@example "coerce the _time column" {
  logsql coerce-time [{_time: "2024-01-01T00:00:00Z", _msg: a}]
} --result [{_time: 2024-01-01T00:00:00Z, _msg: a}]
export def "coerce-time" [rows: any]: nothing -> any {
  let cols = try { $rows | columns } catch { [] }
  if ("_time" in $cols) { $rows | update _time {|r| rfc3339 $r._time } } else { $rows }
}

# The full query path: JSONL body → typed rows with `_time` a datetime.
@category mole-victorialogs
@example "parse and type a query body" {
  logsql query "{\"_time\":\"2024-01-01T00:00:00Z\",\"_msg\":\"hi\",\"level\":\"error\"}"
} --result [{_time: 2024-01-01T00:00:00Z, _msg: hi, level: error}]
export def "query" [body: string]: nothing -> table { coerce-time (jsonl $body) }

# ---- hits ---------------------------------------------------------------------

# A `/hits` payload → tidy rows: one per (bucket, series), `{time, <group…>, hits}`.
# Each series carries its group `fields` (empty when ungrouped), a `timestamps`
# list (RFC3339 strings) and a parallel `values` list (per-bucket counts).
@category mole-victorialogs
@example "one grouped series over two buckets" {
  logsql hits {hits: [{fields: {level: error}, timestamps: ["2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z"], values: [3, 5]}]}
} --result [{time: 2024-01-01T00:00:00Z, level: error, hits: 3}, {time: 2024-01-01T01:00:00Z, level: error, hits: 5}]
export def "hits" [data: any]: nothing -> any {
  if (($data | describe) !~ '^record') { return $data }
  $data | get -o hits | default [] | each {|series|
    let group = ($series | get -o fields | default {})
    ($series | get -o timestamps | default []) | zip ($series | get -o values | default []) | each {|pair|
      {time: (rfc3339 $pair.0)} | merge $group | insert hits $pair.1
    }
  } | flatten
}

# ---- stats (Prometheus-shaped) ------------------------------------------------

# A stats label set → a record, surfacing `__name__` as `metric` and keeping every
# other label as its own column. Defaults `metric` to "value" when `__name__` is
# absent (a bare stats result), so downstream rows always carry a `metric`.
@category mole-victorialogs
@example "__name__ becomes metric" { logsql relabel {__name__: "count(*)", level: info} } --result {level: info, metric: "count(*)"}
@example "no __name__ defaults metric to value" { logsql relabel {level: info} } --result {level: info, metric: value}
export def "relabel" [m: record]: nothing -> record {
  let name = ($m | get -o __name__ | default "value")
  ($m | reject --optional __name__) | insert metric $name
}

# An instant stats (`resultType: vector`) result → one row per series:
# `{..labels, metric, value}` at the single instant.
@category mole-victorialogs
@example "a one-series vector" {
  logsql stats-vector [{metric: {__name__: "count(*)", level: info}, value: [1704153600, "42"]}]
} --result [{level: info, metric: "count(*)", value: 42.0}]
export def "stats-vector" [result: list]: nothing -> table {
  $result | each {|r| (relabel $r.metric) | insert value (num $r.value.1) }
}

# A range stats (`resultType: matrix`) result → tidy rows: one per (series, point),
# `{..labels, metric, time, value}`.
@category mole-victorialogs
@example "a two-point matrix series" {
  logsql stats-matrix [{metric: {__name__: "count(*)"}, values: [[1704067200, "10"], [1704070800, "20"]]}]
} --result [{metric: "count(*)", time: 2024-01-01T00:00:00Z, value: 10.0}, {metric: "count(*)", time: 2024-01-01T01:00:00Z, value: 20.0}]
export def "stats-matrix" [result: list]: nothing -> table {
  $result | each {|r|
    let labels = (relabel $r.metric)
    ($r | get -o values | default []) | each {|p| $labels | insert time (epoch $p.0) | insert value (num $p.1) }
  } | flatten
}

# A `/stats_query` envelope → typed instant rows (dispatches through `stats-vector`).
@category mole-victorialogs
@example "unwrap and type a stats_query envelope" {
  logsql stats {status: success, data: {resultType: vector, result: [{metric: {__name__: "count(*)"}, value: [0, "7"]}]}}
} --result [{metric: "count(*)", value: 7.0}]
export def "stats" [resp: any]: nothing -> any {
  if (($resp | describe) !~ '^record') { return $resp }
  stats-vector ($resp | get -o data | get -o result | default [])
}

# A `/stats_query_range` envelope → typed tidy rows (dispatches through `stats-matrix`).
@category mole-victorialogs
@example "unwrap and type a stats_query_range envelope" {
  logsql stats-range {status: success, data: {resultType: matrix, result: [{metric: {__name__: "count(*)"}, values: [[0, "1"]]}]}}
} --result [{metric: "count(*)", time: 1970-01-01T00:00:00Z, value: 1.0}]
export def "stats-range" [resp: any]: nothing -> any {
  if (($resp | describe) !~ '^record') { return $resp }
  stats-matrix ($resp | get -o data | get -o result | default [])
}

# ---- value / stream enumeration ----------------------------------------------

# A `{"values":[{value,hits}]}` body → a `{value, hits}` table. Covers
# field_names, field_values, stream_field_names, stream_field_values, streams and
# stream_ids. A bare-string value (older servers) is normalized to `{value, hits:
# null}` so the shape is stable.
@category mole-victorialogs
@example "a values payload to rows" {
  logsql values {values: [{value: host-1, hits: 3}, {value: host-2, hits: 5}]}
} --result [{value: host-1, hits: 3}, {value: host-2, hits: 5}]
export def "values" [data: any]: nothing -> any {
  if (($data | describe) !~ '^record') { return $data }
  $data | get -o values | default [] | each {|v|
    if (($v | describe) | str starts-with "record") { $v } else { {value: $v, hits: null} }
  }
}

# A `/facets` payload → `{field, values}` rows, where `values` is a `{value, hits}`
# table. VictoriaLogs names the keys `field_name` / `field_value`; this renames
# them to the tidy `field` / `value`.
@category mole-victorialogs
@example "a facets payload to rows" {
  logsql facets {facets: [{field_name: level, values: [{field_value: error, hits: 4}]}]}
} --result [{field: level, values: [{value: error, hits: 4}]}]
export def "facets" [data: any]: nothing -> any {
  if (($data | describe) !~ '^record') { return $data }
  $data | get -o facets | default [] | each {|f|
    {
      field: ($f | get -o field_name)
      values: (($f | get -o values | default []) | each {|v| {value: ($v | get -o field_value), hits: ($v | get -o hits)} })
    }
  }
}
