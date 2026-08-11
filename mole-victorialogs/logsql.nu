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
# values as strings; these helpers infer a type per column (see `type-rows`). The Prometheus-shaped
# stats endpoints encode sample values as strings and instant timestamps as Unix
# seconds, while `/hits` timestamps are RFC3339 strings — both are handled here.

# `select` is exposed as a verb by mod.nu; that def shadows the `select` builtin
# inside this imported library (same gotcha as mole-sql/sql.nu). Alias it here, in
# this file's scope where `select` still means the builtin, and call the builtin
# through the alias — so `shape`'s projection keeps working after import.
alias core-select = select

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

# ---- query building (pure; mirror of mole-sql's `build-select`) ---------------
# Render a LogsQL string from structured parts for the composable `search` verb.
# No I/O — mod.nu resolves the connection/window and runs the result.

# Render a LogsQL value literal. A bare-safe word (letters, digits, `_ . - *`) is
# left as-is so wildcards and plain tokens stay readable; anything else is
# double-quoted with `\` and `"` escaped, which is what VictoriaLogs needs for
# values carrying spaces or punctuation.
@category mole-victorialogs
@example "a plain word stays bare" { logsql lit "error" } --result "error"
@example "a value with a space is quoted" { logsql lit "web server" } --result "\"web server\""
export def "lit" [v: string]: nothing -> string {
  if ($v =~ '^[\w.*-]+$') { $v } else {
    '"' + ($v | str replace --all '\' '\\' | str replace --all '"' '\"') + '"'
  }
}

# Does a LogsQL filter contain a top-level `|` pipe — an actual pipeline-stage
# boundary — rather than a `|` that is merely a literal inside a quoted string or
# regex? VictoriaLogs quotes strings three ways (`"..."`, `'...'` — both honoring
# `\` escapes — and raw `` `...` ``); those spans are blanked out first, so a regex
# alternation like `app:~"api|web"` reads as pipe-free while `level:error | stats
# count()` does not. This lets the composable verbs stay single-stage without
# falsely rejecting alternation/phrase filters that legitimately carry a `|`.
@category mole-victorialogs
@example "a real pipe stage is detected" { logsql has-pipe "level:error | stats count()" } --result true
@example "a pipe inside a quoted regex is not a stage" { logsql has-pipe 'app:~"api|web"' } --result false
@example "a plain filter has no pipe" { logsql has-pipe "level:error" } --result false
export def "has-pipe" [filter: string]: nothing -> bool {
  ($filter
    | str replace --all --regex '"(?:[^"\\]|\\.)*"' ''      # "double" spans (with escapes)
    | str replace --all --regex "'(?:[^'\\\\]|\\\\.)*'" ''  # 'single' spans (with escapes)
    | str replace --all --regex '`[^`]*`' ''                # `backtick` spans (raw)
  ) | str contains "|"
}

# Assemble a read pipeline: a filter followed by optional stages in fixed order
# (so the result is always valid LogsQL): `stream_context` (surrounding lines) →
# `fields` (keep) → `delete` (drop) → `sort by` → `limit`. An empty filter becomes
# `*` (match everything); empty stages are dropped. `--sort-by` is a list of fields
# rendered `| sort by (a, b)`, ascending unless `--desc`. Mirrors mole-sql's
# `build-select`, which likewise takes an already-rendered filter.
@category mole-victorialogs
@example "a bare filter" {
  logsql build-pipeline "level:error"
} --result "level:error"
@example "all stages compose in order" {
  logsql build-pipeline "level:error" --fields [_time _msg host] --sort-by [_time] --limit 100
} --result "level:error | fields _time, _msg, host | sort by (_time) | limit 100"
@example "a descending multi-field sort" {
  logsql build-pipeline "*" --sort-by [_time host] --desc
} --result "* | sort by (_time, host) desc"
@example "drop columns (the inverse of fields)" {
  logsql build-pipeline "level:error" --drop [_stream_id bytes]
} --result "level:error | delete _stream_id, bytes"
@example "surrounding-line context around each match" {
  logsql build-pipeline "error" --context-after 2
} --result "error | stream_context after 2"
@example "an empty filter matches everything" {
  logsql build-pipeline "" --limit 10
} --result "* | limit 10"
export def "build-pipeline" [
  filter: string                 # the LogsQL filter (empty → `*`)
  --fields: list<string> = []    # projection → `| fields a, b`
  --drop: list<string> = []      # removal → `| delete a, b` (inverse of --fields)
  --sort-by: list<string> = []   # sort fields → `| sort by (a, b)`
  --desc                         # sort descending (default: ascending)
  --limit: int                   # `| limit N`
  --context-before: int          # stream_context: N log lines before each match
  --context-after: int           # stream_context: N log lines after each match
]: nothing -> string {
  [
    (if ($filter | is-empty) { "*" } else { $filter })
    (if ($context_before != null) or ($context_after != null) {
      [
        "| stream_context"
        (if $context_before != null { $"before ($context_before)" })
        (if $context_after != null { $"after ($context_after)" })
      ] | where {|x| $x | is-not-empty } | str join " "
    })
    (if ($fields | is-not-empty) { "| fields " + ($fields | str join ", ") })
    (if ($drop | is-not-empty) { "| delete " + ($drop | str join ", ") })
    (if ($sort_by | is-not-empty) { "| sort by (" + ($sort_by | str join ", ") + ")" + (if $desc { " desc" } else { "" }) })
    (if $limit != null { $"| limit ($limit)" })
  ] | where {|x| $x | is-not-empty } | str join " "
}

# ---- stats building (pure; the aggregation sibling of `build-pipeline`) --------
# Render the `| stats` aggregation pipeline for the composable `stats` verb from
# structured parts. No I/O — mod.nu resolves the connection/window and runs it.

# Sanitize a field name into a valid LogsQL stats result-name suffix: any
# non-word character (notably the `.` in VictoriaLogs' flattened keys like
# `tags.n`) becomes `_`, so an auto-generated alias such as `avg_tags_n` parses.
@category mole-victorialogs
@example "a plain field is unchanged" { logsql stat-alias "latency_ms" } --result "latency_ms"
@example "dotted keys collapse to underscores" { logsql stat-alias "tags.n" } --result "tags_n"
export def "stat-alias" [field: string]: nothing -> string {
  $field | str replace --all --regex '[^\w]' '_'
}

# Assemble a `| stats` pipeline: an optional `by (...)` grouping clause, then the
# aggregation functions, then an optional post-stats `sort by (...)` / `limit`.
# `aggs` is an ordered list of `{expr, name}` records rendered `expr as name`. The
# `by (...)` clause comes BEFORE the functions — the order this VictoriaLogs build
# requires (`stats by (level) count()`, not `stats count() by (level)`). The
# post-stats sort/limit runs over the RESULT columns (server-side top-N). An empty
# filter becomes `*`; empty stages are dropped. Mirrors `build-pipeline`.
@category mole-victorialogs
@example "a bare count" {
  logsql build-stats "*" --aggs [{expr: "count()", name: "count"}]
} --result "* | stats count() as count"
@example "grouped, multi-aggregation" {
  logsql build-stats "level:error" --by [host] --aggs [{expr: "count()", name: "count"} {expr: "avg(latency_ms)", name: "avg_latency_ms"}]
} --result "level:error | stats by (host) count() as count, avg(latency_ms) as avg_latency_ms"
@example "top-N: sort by a result column, then limit" {
  logsql build-stats "*" --by [host] --aggs [{expr: "count()", name: "count"}] --sort-by [count] --desc --limit 10
} --result "* | stats by (host) count() as count | sort by (count) desc | limit 10"
export def "build-stats" [
  filter: string                 # the LogsQL filter (empty → `*`)
  --aggs: list<any> = []         # ordered [{expr, name}] → `expr as name, ...` (the stats functions)
  --by: list<string> = []        # group-by fields → `by (a, b)` (may carry buckets, e.g. `_time:1h`)
  --sort-by: list<string> = []   # post-stats sort over result columns → `| sort by (a, b)`
  --desc                         # sort descending (default: ascending)
  --limit: int                   # post-stats `| limit N`
]: nothing -> string {
  let stats = ([
    "| stats"
    (if ($by | is-not-empty) { "by (" + ($by | str join ", ") + ")" })
    ($aggs | each {|a| $"($a.expr) as ($a.name)" } | str join ", ")
  ] | where {|x| $x | is-not-empty } | str join " ")
  [
    (if ($filter | is-empty) { "*" } else { $filter })
    $stats
    (if ($sort_by | is-not-empty) { "| sort by (" + ($sort_by | str join ", ") + ")" + (if $desc { " desc" } else { "" }) })
    (if $limit != null { $"| limit ($limit)" })
  ] | where {|x| $x | is-not-empty } | str join " "
}

# ---- query (JSONL) ------------------------------------------------------------

# A JSON-lines body → a table of records, one row per non-blank line. Every value
# is the raw string VictoriaLogs returned; `type-rows` does the type inference.
@category mole-victorialogs
@example "two log lines to rows" {
  logsql jsonl "{\"_time\":\"2024-01-01T00:00:00Z\",\"_msg\":\"a\"}\n{\"_time\":\"2024-01-01T00:00:01Z\",\"_msg\":\"b\"}"
} --result [{_time: "2024-01-01T00:00:00Z", _msg: a}, {_time: "2024-01-01T00:00:01Z", _msg: b}]
export def "jsonl" [body: string]: nothing -> table {
  $body | lines | where {|l| ($l | str trim) != "" } | each {|l| $l | from json }
}

# ---- result typing (column-wise inference) ------------------------------------
# VictoriaLogs returns EVERY field as a string. These infer one type per column
# from its values and coerce the whole column to it — all-or-nothing, so a column
# is typed only when every non-empty value fits. That keeps columns homogeneous
# and directly queryable (`where status >= 500`, `sort-by latency_ms`).

# The type to coerce a column to, inferred from its non-empty string values — one
# of int / float / bool / datetime / json / string. Shape-gated (at most one
# conversion attempt per column) and conservative: a single value that does not
# fit keeps the whole column a string. Integer-looking values that carry a leading
# zero ("007") or overflow a 64-bit int stay strings — they are identifiers, not
# numbers — caught by a round-trip check, since `into int` silently saturates on
# overflow (a plain try/catch would not notice).
@category mole-victorialogs
@example "a clean integer column" { logsql col-kind ["500" "200" "0"] } --result "int"
@example "leading zeros are identifiers, not ints" { logsql col-kind ["007" "012"] } --result "string"
@example "an overflowing int stays a string" { logsql col-kind ["123456789012345678901234"] } --result "string"
@example "decimals are floats" { logsql col-kind ["12.5" "0.4"] } --result "float"
@example "booleans" { logsql col-kind ["true" "false"] } --result "bool"
@example "rfc3339 timestamps" { logsql col-kind ["2026-08-10T10:00:00Z"] } --result "datetime"
@example "json arrays / objects" { logsql col-kind ["[1,2]" "[3]"] } --result "json"
@example "one misfit keeps the column a string" { logsql col-kind ["500" "n/a"] } --result "string"
@example "no evidence → string" { logsql col-kind [] } --result "string"
export def "col-kind" [vals: list<string>]: nothing -> string {
  if ($vals | is-empty) { return "string" }
  let check = {|re| $vals | all {|v| $v =~ $re } }
  if ($vals | all {|v| $v in ["true" "false"] }) { "bool"
  } else if (do $check '^-?\d+$') {
    # round-trips iff clean: rejects leading zeros AND silent i64 overflow
    if ($vals | all {|v| (try { ($v | into int | into string) == $v } catch { false }) }) { "int" } else { "string" }
  } else if (do $check '^-?(?:\d+\.\d*|\.\d+|\d+)(?:[eE][+-]?\d+)?$') {
    let safe = (not ($vals | any {|v| $v =~ '^-?0[0-9]' }))       # no leading-zero integer part
    if $safe and ($vals | all {|v| (try { ($v | into float | into string) not-in ["inf" "-inf" "NaN"] } catch { false }) }) { "float" } else { "string" }
  } else if (do $check '^\d{4}-\d{2}-\d{2}') {
    if ($vals | all {|v| (try { $v | into datetime; true } catch { false }) }) { "datetime" } else { "string" }
  } else if (do $check '^\s*[\[{]') {
    if ($vals | all {|v| (try { $v | from json; true } catch { false }) }) { "json" } else { "string" }
  } else { "string" }
}

# Coerce one raw string cell to `kind`. A missing / empty cell becomes null, so a
# typed column carries null rather than "" for absent values.
@category mole-victorialogs
@example "cast an int cell" { logsql cast "500" "int" } --result 500
@example "an empty cell becomes null" { logsql cast "" "int" } --result null
export def "cast" [v: any, kind: string]: nothing -> any {
  if ($v | is-empty) { return null }
  match $kind {
    "int" => ($v | into int)
    "float" => ($v | into float)
    "bool" => ($v == "true")
    "datetime" => (rfc3339 $v)
    "json" => (try { $v | from json } catch { $v })
    "stream" => (parse-stream $v)
    _ => $v
  }
}

# Parse a VictoriaLogs `_stream` selector — `{label="value",…}` — into a record of
# its labels, so `_stream.host` is a real field (and `group-by _stream` still
# works). Handles quoted values that contain commas or escaped quotes. An empty
# selector `{}` is an empty record; anything that isn't a selector is returned
# unchanged, so a surprising value is never silently dropped.
@category mole-victorialogs
@example "a selector becomes a record of its labels" {
  logsql parse-stream '{app="api",host="h1"}'
} --result {app: api, host: h1}
@example "an empty selector is an empty record" { logsql parse-stream "{}" } --result {}
export def "parse-stream" [s: string]: nothing -> any {
  let inner = ($s | str trim | str trim --left --char '{' | str trim --right --char '}')
  if ($inner | str trim | is-empty) { return {} }
  let pairs = ($inner | parse --regex '(?<k>[a-zA-Z_][\w.]*)="(?<v>(?:[^"\\]|\\.)*)"')
  if ($pairs | is-empty) { return $s }
  $pairs | reduce --fold {} {|m, acc|
    $acc | insert $m.k ($m.v | str replace --all '\"' '"' | str replace --all '\\' '\')
  }
}

# Infer a type per column (via `col-kind`) and coerce the whole table. The
# VictoriaLogs reserved fields are fixed: `_time` is a datetime, `_stream` a record
# of its labels; `_msg` / `_stream_id` stay strings (a message that looks numeric
# is still a message). Absent cells are left absent, so a sparse log schema is
# preserved. (Kinds are kept as a list, not a record, so VL's dotted flattened keys
# like `tags.n` are matched literally, not as nested cell paths.)
@category mole-victorialogs
@example "a mixed log row becomes typed" {
  logsql type-rows [{_time: "2026-08-10T10:00:00Z", _msg: "hi", _stream: "{host=\"h1\"}", status: "500", cached: "true"}]
} --result [{_time: 2026-08-10T10:00:00Z, _msg: hi, _stream: {host: h1}, status: 500, cached: true}]
export def "type-rows" [rows: any]: nothing -> any {
  let cols = (try { $rows | each {|r| $r | columns } | flatten | uniq } catch { [] })
  if ($cols | is-empty) { return $rows }
  let kinds = ($cols | each {|c|
    let k = if $c in ["_msg" "_stream_id"] { "string"
    } else if $c == "_time" { "datetime"
    } else if $c == "_stream" { "stream"
    } else { col-kind ($rows | each {|r| $r | get -o $c } | where {|v| $v | is-not-empty }) }
    {col: $c, kind: $k}
  } | where kind != "string")
  $rows | each {|row|
    $kinds | reduce --fold $row {|t, r|
      if ($t.col in ($r | columns)) { $r | update $t.col (cast ($r | get -o $t.col) $t.kind) } else { $r }
    }
  }
}

# The full query path: JSONL body → column-typed rows.
@category mole-victorialogs
@example "parse and type a query body" {
  logsql query "{\"_time\":\"2024-01-01T00:00:00Z\",\"_msg\":\"hi\",\"level\":\"error\",\"status\":\"500\"}"
} --result [{_time: 2024-01-01T00:00:00Z, _msg: hi, level: error, status: 500}]
export def "query" [body: string]: nothing -> table { type-rows (jsonl $body) }

# ---- output verbosity ---------------------------------------------------------

# The columns a `compact` view keeps, in priority order: when / severity / source
# / what. Adaptive — only those actually present in the data are shown, so a
# dataset without a `level` (or `_stream`) simply omits it rather than carrying a
# null column.
const COMPACT_FIELDS = [_time level _stream _msg]

# Project log rows to an output verbosity — purely reshaping the view, never the
# values (applied after typing, so `full`/`wide`/`compact` all carry the same
# typed cells). `full` keeps every column (the log in all its glory); `wide` drops
# VictoriaLogs' meta columns `_stream_id` for a fuller-but-clean view; `compact`
# (the default) keeps just the triage essentials — `_time`, `level`, `_stream`,
# `_msg` — whichever of those the data actually has. `wide`/`full` preserve each
# row's columns as-is (sparse rows stay sparse). An unknown mode falls back to
# `compact`.
@category mole-victorialogs
@example "compact keeps the triage essentials present in the data" {
  logsql shape [{_time: 2024-01-01T00:00:00Z, _msg: hi, _stream: {host: h1}, _stream_id: "00", level: error, status: 500}] "compact"
} --result [{_time: 2024-01-01T00:00:00Z, level: error, _stream: {host: h1}, _msg: hi}]
@example "wide drops only the internal _stream_id" {
  logsql shape [{_time: 2024-01-01T00:00:00Z, _msg: hi, _stream: {host: h1}, _stream_id: "00", level: error}] "wide"
} --result [{_time: 2024-01-01T00:00:00Z, _msg: hi, _stream: {host: h1}, level: error}]
@example "full is the untouched rows" {
  logsql shape [{_time: 2024-01-01T00:00:00Z, _msg: hi, _stream_id: "00"}] "full"
} --result [{_time: 2024-01-01T00:00:00Z, _msg: hi, _stream_id: "00"}]
export def "shape" [rows: any, mode: string]: nothing -> any {
  match $mode {
    "full" => $rows
    "wide" => ($rows | each {|r| $r | reject --optional _stream_id })
    _ => {
      let present = ($rows | each {|r| $r | columns } | flatten | uniq)
      let keep = ($COMPACT_FIELDS | where {|c| $c in $present })
      if ($keep | is-empty) { $rows } else { $rows | each {|r| $r | core-select --optional ...$keep } }
    }
  }
}

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

# Pivot the tidy Prometheus-shaped stats rows (`{..labels, metric, value}`, plus a
# `time` column for a range series) into WIDE rows — one row per group, each
# aggregation its own column (`{level, count, avg_bytes}`). The group key is every
# column except `metric`/`value`; `--keys` gives those columns a leading order (the
# `by` fields, `time` first for a series) and `--cols` orders the aggregation
# columns (their flag order). First-seen group order is preserved, so a server-side
# top-N `sort`/`limit` survives the pivot; the result is rectangular — a group
# missing an aggregation gets a null in that column. Non-stats input is returned
# unchanged. This wide reshape is what makes the structured `stats` verb read like
# SQL GROUP BY, while `raw-stats` keeps the tidy long shape.
@category mole-victorialogs
@example "instant: one row per group, a column per aggregation" {
  logsql stats-wide [{level: error, metric: count, value: 2} {level: error, metric: avg_bytes, value: 512.0} {level: info, metric: count, value: 3}] --keys [level] --cols [count avg_bytes]
} --result [{level: error, count: 2, avg_bytes: 512.0} {level: info, count: 3, avg_bytes: null}]
@example "range: time leads each row" {
  logsql stats-wide [{level: error, metric: count, value: 2, time: 2024-01-01T00:00:00Z}] --keys [time level] --cols [count]
} --result [{time: 2024-01-01T00:00:00Z, level: error, count: 2}]
export def "stats-wide" [
  rows: any
  --keys: list<string> = []      # key columns to lead with, in order (else inferred)
  --cols: list<string> = []      # aggregation columns, in order (else first-seen)
]: nothing -> any {
  if (($rows | describe) !~ '^(table|list)') { return $rows }
  if ($rows | is-empty) { return $rows }
  let present = ($rows | each {|r| $r | columns } | flatten | uniq)
  if ("metric" not-in $present) { return $rows }
  let keycols = (
    ($keys | where {|k| $k in $present })
    ++ ($present | where {|c| ($c not-in ["metric" "value"]) and ($c not-in $keys) })
  )
  let wide = ($rows | reduce --fold [] {|r, acc|
    let keyrec = ($keycols | reduce --fold {} {|k, m| $m | insert $k ($r | get -o $k) })
    let name = ($r | get -o metric | into string)
    let hit = ($acc | enumerate | where {|e| $keycols | all {|k| ($e.item | get -o $k) == ($keyrec | get -o $k) } } | get -o 0)
    if ($hit == null) {
      $acc | append ($keyrec | upsert $name ($r | get -o value))
    } else {
      $acc | update $hit.index {|row| $row | upsert $name ($r | get -o value) }
    }
  })
  let metriccols = ($wide | each {|r| $r | columns } | flatten | uniq | where {|c| $c not-in $keycols })
  let ordered = (($cols | where {|c| $c in $metriccols }) ++ ($metriccols | where {|c| $c not-in $cols }))
  $wide | each {|r| $r | core-select --optional ...($keycols ++ $ordered) }
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
