# mole-victorialogs — VictoriaLogs driver plugin (READ-ONLY LogsQL HTTP API).
#
# A PLUGIN (data source): supports the `victorialogs` driver, registers itself as
# a driver, and exposes read-only verbs — `raw-query` / `select` / `hits` /
# `raw-stats` / `stats` / `fields` / `field-values` / `streams` / `facets` /
# `set-connection`. It talks to
# VictoriaLogs over its HTTP API using Nushell's built-in `http` (no external
# CLI), with no external dependencies.
#
# LAYERING (two files, like mole-prometheus's client+wrapper split):
#   - client.nu  — HAND-WRITTEN, mechanical HTTP layer for the read-only
#                  `/select/logsql/` POST endpoints: base URL, multi-tenancy +
#                  auth headers, form-urlencoding, timeouts, non-2xx raising. It
#                  returns lightly-parsed data (raw JSONL text for `raw-query`, a
#                  `from json` record otherwise). Hand-written, not generated,
#                  because VictoriaLogs ships no OpenAPI spec and its endpoints
#                  are POST form-urlencoded (see client.nu header).
#   - logsql.nu  — PURE response→typed-rows transforms (JSONL→table with
#                  per-column type inference, hits pivot, Prometheus-shaped stats
#                  shaping, value/facets parsing) plus the time/duration formatting
#                  VictoriaLogs wants. No I/O, no clock — unit-tested directly.
#   - mod.nu     — THIS wrapper. It owns policy: connection resolution,
#                  time-range ergonomics, turning each payload into typed rows,
#                  and the completion catalog. Read-only is structural.
#
# Both helper modules are imported PRIVATELY (`use ./client.nu`, `use
# ./logsql.nu`), so their `client query`, `logsql num`, … never leak into
# `use mole-victorialogs`.

use mole/lib/conn.nu

# Driver-scoped connection completer: only THIS driver (victorialogs), never other drivers.
def "complete-connection" []: nothing -> list<string> { conn names "victorialogs" }
use mole/lib/cache.nu
use mole/lib/query.nu
use mole/lib/complete.nu
use ./client.nu
use ./logsql.nu

export-env {
  conn register "victorialogs"
}

# ---- connection resolution ----------------------------------------------------

# Resolve a victorialogs connection (named, or the current one) and apply ad-hoc
# `--url`/`--token`/`--set` overrides. Null overrides are dropped (see `conn
# override`), so unset flags are no-ops. Asserts the connection is a victorialogs
# one (via conn resolve --driver).
def vl-conf [connection: any, url: any, token: any, set: record]: nothing -> record {
  conn with victorialogs $connection ({url: $url, token: $token} | merge $set)
}

# ---- time range ---------------------------------------------------------------
# (Pure time/duration formatting lives in logsql.nu; only this reads the clock.)

# Resolve --last / --start / --end into a {start, end} of datetimes (either may be
# null = unbounded). Explicit --start/--end win; --last is "now minus dur",
# defaulting the missing end to now.
def vl-range [last: any, start: any, end: any]: nothing -> record {
  let e = if ($end | is-not-empty) { $end } else if ($last | is-not-empty) { (date now) } else { null }
  let s = if ($start | is-not-empty) { $start } else if ($last | is-not-empty) { (date now) - $last } else { null }
  {start: $s, end: $e}
}

# ---- completion catalog (field names) -----------------------------------------

# Load the completion catalog for a connection: {meta, fields}. Cached for a day.
# `--refresh` rebuilds; otherwise a fresh cache is returned as-is. The catalog
# calls are short-timeout and only power tab-completion. `fields` unions the log
# field names and the stream field names present over all time.
def vl-catalog-load [conf: record, --refresh]: nothing -> record {
  let file = (cache path "victorialogs" ($conf | get -o name | default "_"))
  if (not $refresh) and (not (cache stale $file 1day)) { return (cache read $file) }
  let fields = (
    (client field-names $conf "*" | logsql values $in | get -o value | default [])
    ++ (client stream-field-names $conf "*" | logsql values $in | get -o value | default [])
  ) | uniq | sort
  let data = {meta: {connection: ($conf | get -o name), driver: "victorialogs", refreshed_at: (date now)}, fields: $fields}
  $data | cache write $file
  $data
}

# Warm the catalog after a successful query, but only when it is cold (missing).
# Best-effort: the connection is known reachable here, so this is cheap and never
# breaks the calling command. `set-connection` is the explicit refresh point.
def vl-warm [conf: record]: nothing -> nothing {
  let file = (cache path "victorialogs" ($conf | get -o name | default "_"))
  if (cache read $file | is-not-empty) { return }
  try { vl-catalog-load $conf | ignore } catch { }
}

# Read a flag's value out of a completion-context command line (last wins).
def vl-flag [ctx: string, names: list<string>]: nothing -> any {
  let m = ($ctx | parse --regex ('(?:' + ($names | str join "|") + ')[\s=]+(?P<v>[^\s]+)'))
  if ($m | is-empty) { null } else { $m | last | get v }
}

# The explicit `field:…` filter tokens already on the line, AND-joined into a LogsQL
# scoping filter for contextual lookups (empty → `*`). The parser (`ast`) does the
# flag/positional split, so flag values (`--select a,b`, `--url http://h:8428`,
# `--start <datetime>`) are excluded without a hand-kept switch list, and quoted tokens
# stay whole; only structured `field:value` positionals scope (bare terms are ignored).
# The token under the cursor is dropped first (it is the one being completed). `ast` is
# a debug builtin whose JSON is not a stable contract, so a parse mismatch is caught and
# scoping simply falls back to `*` (global) — it never breaks completion.
def vl-filters-ctx [context: string]: nothing -> string {
  let prior = ($context | split row " " | drop 1 | str join " ")
  let f = (try {
    ast $prior --json | get block | from json
    | get pipelines.0.elements.0.expr.expr.Call.arguments
    | where {|a| "Positional" in ($a | columns) }
    | each {|a| $a.Positional.expr | get -o String }
    | compact
    | where {|t| $t | str contains ":" }
    | str join " "
  } catch { "" })
  if ($f | is-empty) { "*" } else { $f }
}

# The {start, end} window implied by the --last/--start/--end flags already on the
# line, best-effort (absent/unparseable → unbounded). Lets contextual lookups honor
# the time window the user has typed.
def vl-range-ctx [context: string]: nothing -> record {
  let lastRaw = (vl-flag $context ["--last" "-L"])
  let startRaw = (vl-flag $context ["--start" "-a"])
  let endRaw = (vl-flag $context ["--end" "-b"])
  let last = (if ($lastRaw | is-empty) { null } else { try { $lastRaw | into duration } catch { null } })
  let start = (if ($startRaw | is-empty) { null } else { try { $startRaw | into datetime } catch { null } })
  let end = (if ($endRaw | is-empty) { null } else { try { $endRaw | into datetime } catch { null } })
  vl-range $last $start $end
}

# The cached catalog for whatever connection the command line names (or the current
# one). Cache-only — the instant fallback that `vl-field` drops back to when its live
# scoped lookup is empty or errors.
def vl-catalog-ctx [context: string]: nothing -> record {
  complete catalog-ctx $context victorialogs
}

# Field-name suggestions, scoped to the filters + window already on the line: a LIVE
# `field_names` ∪ `stream_field_names` (short timeout) reflecting what actually exists
# in the current query, falling back to the cached global catalog on empty/error.
# Opt-in contextual completion — this hits the network per tab (the cache is only the
# fallback), unlike the instant cache-only catalog it draws that fallback from.
def "vl-field" [context: string]: nothing -> list<string> {
  let cached = (vl-catalog-ctx $context | get -o fields | default [])
  try {
    let conf = (vl-conf (vl-flag $context ["--connection" "-c"]) null null {})
    let filter = (vl-filters-ctx $context)
    let r = (vl-range-ctx $context)
    let s = (logsql vl-time $r.start)
    let e = (logsql vl-time $r.end)
    let live = (
      (client field-names $conf $filter --start $s --end $e --timeout 3sec | logsql values $in | get -o value | default [])
      ++ (client stream-field-names $conf $filter --start $s --end $e --timeout 3sec | logsql values $in | get -o value | default [])
    ) | uniq | sort
    if ($live | is-empty) { $cached } else { $live }
  } catch { $cached }
}

# The token under the cursor: the last whitespace-delimited chunk of a completion
# context. Both list-style completers below reason about it.
def vl-token [context: string]: nothing -> string { $context | split row " " | last }

# Split a comma-separated flag value into a clean list (trims, drops blanks).
def vl-csv [v: any]: nothing -> list<string> {
  $v | default "" | split row "," | str trim | where {|x| $x | is-not-empty }
}

# Completer for the `--output` verbosity flag (see `logsql shape`).
def "vl-output" []: nothing -> list<string> { ["compact" "wide" "full"] }

# Rest-positional completer for `select` filter tokens. TWO STAGES on the token, both
# contextual to the OTHER `field:…` filters and the time window already on the line:
#   - no `:` → field-name stage: `field:` for each field (`vl-field`, live-scoped).
#   - `field:…` → value stage: a LIVE `field_values` call scoped by the sibling
#                 filters + window (short timeout), so `app:web level:er⇥` completes
#                 only levels seen in `app:web`. Best-effort — errors → no candidates.
# Nushell keeps `:` inside the word, so a `field:value` candidate replaces the whole
# token and is prefix-filtered for us.
def "vl-filter" [context: string]: nothing -> list<string> {
  let tok = (vl-token $context)
  if not ($tok | str contains ":") {
    vl-field $context | each {|f| $"($f):" }
  } else {
    try {
      let field = ($tok | split row ":" | first)
      let conf = (vl-conf (vl-flag $context ["--connection" "-c"]) null null {})
      let r = (vl-range-ctx $context)
      client field-values $conf (vl-filters-ctx $context) $field --start (logsql vl-time $r.start) --end (logsql vl-time $r.end) --limit 50 --timeout 3sec
      | logsql values $in | get -o value | default []
      | each {|v| $"($field):(logsql lit ($v | into string))" }
    } catch { [] }
  }
}

# Completer for the comma-separated `--select` flag. Nushell won't complete inside
# a `list<string>` `[...]` literal, so it takes a comma-joined string; this
# re-prepends the already-typed values so accepting a candidate extends the list
# (`_time,ho⇥` → `_time,host`). The prefix is the token with its partial last
# segment stripped.
def "vl-fields-csv" [context: string]: nothing -> list<string> {
  let prefix = (vl-token $context | str replace --regex '[^,]*$' '')
  vl-field $context | each {|f| $"($prefix)($f)" }
}

# Completer for `select`'s `--sort-by` / `--drop`: the `--select` projection when one
# is on the line (you can only sort or drop within the columns you kept), else the
# full contextual field list. Comma-list aware, like `vl-fields-csv`.
def "vl-proj-csv" [context: string]: nothing -> list<string> {
  let prefix = (vl-token $context | str replace --regex '[^,]*$' '')
  let proj = (vl-csv (vl-flag $context ["--select" "-S"]))
  let fields = (if ($proj | is-not-empty) { $proj } else { vl-field $context })
  $fields | each {|f| $"($prefix)($f)" }
}

# Build the ordered [{expr, name}] stats aggregations from the metric flags. Each
# field-list flag expands to one function per field, with an auto-derived result
# column (`avg_<f>`, `p99_<f>`, `uniq_<f>`, …; dots sanitized via `logsql
# stat-alias`); the fieldless `--count` (row count) becomes `count`. Order follows
# the parameter order below, fields left-to-right. An empty selection defaults to a
# single `count()` — so `stats --by level` counts rows per level. Shared by the
# `stats` verb and its `--sort-by` completer, which needs the same result names.
def vl-aggs [
  count: bool, count_uniq: any, sum: any, avg: any, min: any, max: any,
  median: any, p90: any, p95: any, p99: any
]: nothing -> list {
  let f = {|func: string, prefix: string, fields: any|
    vl-csv $fields | each {|x| {expr: ($func + "(" + $x + ")"), name: ($prefix + "_" + (logsql stat-alias $x))} }
  }
  let q = {|phi: string, prefix: string, fields: any|
    vl-csv $fields | each {|x| {expr: ("quantile(" + $phi + ", " + $x + ")"), name: ($prefix + "_" + (logsql stat-alias $x))} }
  }
  let specs = ([
    (if $count { [{expr: "count()", name: "count"}] })
    (do $f "count_uniq" "uniq" $count_uniq)
    (do $f "sum" "sum" $sum)
    (do $f "avg" "avg" $avg)
    (do $f "min" "min" $min)
    (do $f "max" "max" $max)
    (do $f "median" "median" $median)
    (do $q "0.9" "p90" $p90)
    (do $q "0.95" "p95" $p95)
    (do $q "0.99" "p99" $p99)
  ] | compact | flatten)
  if ($specs | is-empty) { [{expr: "count()", name: "count"}] } else { $specs }
}

# Completer for the post-stats `--sort-by`: the RESULT columns, not log fields —
# the `--by` group fields plus the aggregation columns implied by the metric flags
# already on the command line (`--count`→`count`, `--avg lat`→`avg_lat`).
# Reconstructed from the context (like `vl-flag`) so server-side top-N completes.
# Comma-list aware, mirroring `vl-fields-csv`.
def "vl-stat-cols" [context: string]: nothing -> list<string> {
  let prefix = (vl-token $context | str replace --regex '[^,]*$' '')
  let by = (vl-csv (vl-flag $context ["--by" "-g"]))
  let aggs = (vl-aggs
    ($context =~ '(?:--count|-C)(?:\s|$)')
    (vl-flag $context ["--count-uniq"]) (vl-flag $context ["--sum"]) (vl-flag $context ["--avg"])
    (vl-flag $context ["--min"]) (vl-flag $context ["--max"]) (vl-flag $context ["--median"])
    (vl-flag $context ["--p90"]) (vl-flag $context ["--p95"]) (vl-flag $context ["--p99"]))
  ($by ++ ($aggs | get name)) | each {|c| $"($prefix)($c)" }
}

# ---- execution ----------------------------------------------------------------

# Compose a LogsQL *filter* from AND-joined filter tokens. LogsQL ANDs
# space-separated filters, so the tokens are space-joined; an empty result becomes
# `*` (match everything). A top-level `|` pipe is rejected — a filter token may not
# smuggle its own pipeline stage; `raw-query` is the escape hatch for that. The check
# is quote-aware (`logsql has-pipe`), so a `|` inside a quoted regex/phrase (e.g.
# `app:~"api|web"`) is allowed. Shared by `select` and the enumeration verbs
# (`fields`/`field-values`/`streams`/`facets`), which all take completing filter
# tokens instead of a raw query string. Raw filter syntax (regex, `OR`, ranges) is
# just a quoted token — there is no separate `--where`.
def vl-compose-filter [filters: list<string>]: nothing -> string {
  let filter = ($filters | where {|p| $p | is-not-empty } | str join " ")
  if (logsql has-pipe $filter) {
    error make {msg: "a '|' pipe isn't allowed in a filter token — use `raw-query` for a full LogsQL pipeline"}
  }
  if ($filter | is-empty) { "*" } else { $filter }
}

# Fetch a resolved LogsQL query, warm the catalog, and return typed rows projected
# to the `output` verbosity. Shared by `raw-query` and `select` — they differ only in
# how `$q` is produced. `raw` skips the `_time` datetime coercion; `output` is one
# of compact/wide/full (see `logsql shape`). (`limit`/`offset` are `any` so a null
# passes straight through to the client's int flags.)
def vl-run [conf: record, q: string, range: record, limit: any, offset: any, raw: bool, output: string]: nothing -> any {
  let body = (client query $conf $q
    --start (logsql vl-time $range.start) --end (logsql vl-time $range.end) --limit $limit --offset $offset)
  vl-warm $conf
  let rows = if $raw { logsql jsonl $body } else { logsql query $body }
  logsql shape $rows $output
}

# ---- user verbs ---------------------------------------------------------------

# Run a LogsQL query, returning one typed row per matching log entry.
#
# The expression is the positional <expr>, a saved `--file` (resolved under the
# query dir with a `.logsql` suffix), or `$EDITOR` when neither is given. Each row
# is a log entry — every field a column. VictoriaLogs returns every value as a
# string, so each column's type is inferred from its values (`_time` a datetime,
# all-numeric columns int/float, `true`/`false` bool, JSON arrays/objects parsed,
# the `_stream` selector a record of its labels); `--raw` returns the untouched
# strings. `--output` sets the column verbosity: `compact` (the default — the
# triage essentials `_time`/`level`/`_stream`/`_msg` that the data has), `wide`
# (drops only the internal `_stream_id`) or `full`
# (every column). The window is `--last` (now minus a
# duration) or explicit `--start`/`--end`; `--limit` caps the number of latest
# entries and `--offset` paginates. Connection is the current victorialogs one
# unless `--connection` names another; `--url`/`--token`/`--set` override fields.
@category mole-victorialogs
@example "the last hour of errors" { mole-victorialogs raw-query 'level:error' --last 1hr --limit 100 }
@example "an explicit window" { mole-victorialogs raw-query '*' --start 2026-07-26T00:00:00Z --end 2026-07-26T06:00:00Z }
@example "the full row, every column" { mole-victorialogs raw-query 'level:error' --last 1hr --output full }
@example "a saved query against a named connection" { mole-victorialogs raw-query --file dashboards/errors.logsql -c prod }
@example "query text piped via stdin" { mole query show dashboards/errors.logsql | mole-victorialogs raw-query -c prod }
export def "raw-query" [
  expr?: string                                    # LogsQL expression (else --file, else stdin, else $EDITOR)
  --file(-f): string@"complete queryfile"          # saved query file (relative to the query dir)
  --last(-L): duration                             # window ending now (shorthand for --start (now - dur))
  --start(-a): datetime                            # window start (overrides --last)
  --end(-b): datetime                              # window end (default: now when --last is given)
  --limit(-l): int                                 # return up to N latest entries
  --offset(-o): int                                # skip N entries (pagination)
  --output(-O): string@"vl-output" = "compact"     # column verbosity: compact | wide | full
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string                                    # override the connection URL
  --token: string                                  # override the bearer token
  --set: record = {}                               # override any other connection field(s)
  --raw(-R)                                         # raw strings: skip all type inference
] {
  let conf = (vl-conf $connection $url $token $set)
  let q = ($in | query resolve $expr --file $file --suffix ".logsql")
  vl-run $conf $q (vl-range $last $start $end) $limit $offset $raw $output
}

# Compose and run a LogsQL log query from the command line, with completion.
#
# The autocompleting mirror of `raw-query`: instead of writing the LogsQL by hand you
# assemble it from flags, and every part tab-completes. The `...filters` are LogsQL
# filter tokens (`error`, `level:error`, `status:>=500`), space-joined with AND and
# passed through verbatim; each completes the field name first, then (via a live
# lookup) that field's values. A token that won't complete is still fine — any raw
# LogsQL filter (a regex, `OR`, a range) works as a quoted token, e.g.
# `'app:~"api-.*"'`. `--select` projects columns (`| fields …`, completing) and
# `--drop` removes them (`| delete …`, completing) — the inverse; `--sort-by` is a
# completing comma-list of fields (`| sort by (…)`), ascending unless `--desc`;
# `--limit` caps; `--before`/`--after` pull N surrounding log lines around each
# match (`| stream_context`). Rows come back typed like `raw-query` (`--raw` keeps the
# raw strings), and `--output` sets the column verbosity (compact | wide | full).
# The window and connection flags are exactly `raw-query`'s. Single-stage on purpose —
# a `|` in a filter token is rejected; reach for `raw-query` for an arbitrary pipeline
# (or a mixed-direction sort). `--dry-run` returns `{connection, query}` — the
# resolved connection (secrets dropped) and the composed LogsQL — without running it.
@category mole-victorialogs
@example "compose a filtered, projected, ordered query" {
  mole-victorialogs select level:error status:>=500 --select _time,host,_msg --sort-by _time --desc --limit 100 --last 1hr --dry-run | get query
} --result "level:error status:>=500 | fields _time, host, _msg | sort by (_time) desc | limit 100"
@example "a raw filter is just another token, AND-joined" {
  mole-victorialogs select timeout 'app:~"api-.*"' --dry-run | get query
} --result "timeout app:~\"api-.*\""
@example "drop noisy columns, keep the rest" {
  mole-victorialogs select level:error --drop _stream_id,bytes --dry-run | get query
} --result "level:error | delete _stream_id, bytes"
@example "2 lines of context around each match" {
  mole-victorialogs select 'db timeout' --after 2 --dry-run | get query
} --result "db timeout | stream_context after 2"
@example "no filters matches everything" {
  mole-victorialogs select --limit 10 --dry-run | get query
} --result "* | limit 10"
@example "newest first against a named connection" {
  mole-victorialogs select level:error --sort-by _time --desc --last 1hr -c prod
}
export def "select" [
  ...filters: string@"vl-filter"                   # LogsQL filter tokens (AND-joined): error  level:error  status:>=500
  --select(-S): string@"vl-fields-csv"             # projected fields, comma-separated → `| fields ...`
  --drop(-D): string@"vl-proj-csv"                 # fields to remove, comma-separated → `| delete ...` (inverse of --select)
  --sort-by(-s): string@"vl-proj-csv"              # sort fields, comma-separated → `| sort by (...)`
  --desc(-d)                                       # sort descending (default: ascending)
  --limit(-l): int                                 # `| limit N`
  --before: int                                    # stream_context: N log lines before each match
  --after: int                                     # stream_context: N log lines after each match
  --last(-L): duration                             # window ending now (shorthand for --start (now - dur))
  --start(-a): datetime                            # window start (overrides --last)
  --end(-b): datetime                              # window end (default: now when --last is given)
  --offset(-o): int                                # skip N entries (pagination)
  --output(-O): string@"vl-output" = "compact"     # column verbosity: compact | wide | full
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string                                    # override the connection URL
  --token: string                                  # override the bearer token
  --set: record = {}                               # override any other connection field(s)
  --raw(-R)                                         # raw strings: skip all type inference
  --dry-run(-n)                                     # return {connection, query} instead of running
] {
  let conf = (vl-conf $connection $url $token $set)
  # Single-stage by design: a filter token may not smuggle its own pipe (enforced
  # by vl-compose-filter). `raw-query` is the escape hatch for a full LogsQL pipeline.
  let filter = (vl-compose-filter $filters)
  let q = (logsql build-pipeline $filter
    --fields (vl-csv $select) --drop (vl-csv $drop)
    --sort-by (vl-csv $sort_by) --desc=$desc --limit $limit
    --context-before $before --context-after $after)
  if $dry_run { return {connection: ($conf | conn redact), query: $q} }
  # Limit rides the `| limit` pipe in $q (so it applies after the sort), not the client param.
  vl-run $conf $q (vl-range $last $start $end) null $offset $raw $output
}

# Per-bucket hit counts over time. Returns tidy `{time, <group>, hits}` rows.
#
# Like `select`, the log set is composed from `...filters` — LogsQL filter tokens
# (`level:error`, `status:>=500`) AND-joined and tab-completing field → value (a raw
# regex/`OR` filter is just a quoted token); no filters counts everything. `--step`
# sets the bucket width (server default is auto); `--field` groups the counts by that
# field's values, so each row carries the group columns. The window is `--last` or
# `--start`/`--end`.
@category mole-victorialogs
@example "hourly error counts over a day" { mole-victorialogs hits level:error --last 1day --step 1hr }
@example "counts grouped by level" { mole-victorialogs hits --last 6hr --step 30min --field level }
@example "inspect the composed filter without running" { mole-victorialogs hits level:error --dry-run | get query } --result "level:error"
export def "hits" [
  ...filters: string@"vl-filter"                   # LogsQL filter tokens (AND-joined): error  level:error  status:>=500
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --step(-s): duration                             # bucket width (default: server auto)
  --field(-F): string@"vl-field"                   # group counts by this field's values
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
  --dry-run(-n)                                    # return {connection, query} instead of running
] {
  let conf = (vl-conf $connection $url $token $set)
  let filter = (vl-compose-filter $filters)
  if $dry_run { return {connection: ($conf | conn redact), query: $filter} }
  let range = (vl-range $last $start $end)
  (client hits $conf $filter
    --start (logsql vl-time $range.start) --end (logsql vl-time $range.end)
    --step (logsql step $step) --field $field)
  | logsql hits $in
}

# Run a stats query — the LogsQL must contain a `| stats` pipe.
#
# Instant by default: one row per result series, `{..labels, metric, value}` at
# `--time` (server now when omitted). With `--range` it returns a tidy time series
# instead — one row per (series, point), `{..labels, metric, time, value}` over the
# `--last` / `--start`/`--end` window at `--step` resolution (default 1hr).
@category mole-victorialogs
@example "instant counts by level" { mole-victorialogs raw-stats 'error | stats by (level) count()' }
@example "a daily time series" { mole-victorialogs raw-stats '* | stats by (level) count()' --range --last 1day --step 1hr }
export def "raw-stats" [
  expr: string                                     # LogsQL ending in `| stats ...`
  --time(-t): datetime                             # instant to evaluate at (default: server now)
  --range(-r)                                       # time series instead of a single instant
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --step(-s): duration = 1hr                       # series step (with --range)
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
] {
  let conf = (vl-conf $connection $url $token $set)
  if $range {
    let r = (vl-range $last $start $end)
    (client stats-query-range $conf $expr
      --start (logsql vl-time $r.start) --end (logsql vl-time $r.end) --step (logsql step $step))
    | logsql stats-range $in
  } else {
    (client stats-query $conf $expr --time (logsql vl-time $time)) | logsql stats $in
  }
}

# Compose and run a LogsQL stats aggregation from the command line, with completion.
#
# The autocompleting brother of `raw-stats`: instead of hand-writing the `| stats`
# pipe you pick aggregations as flags and every part completes. The `...filters`
# are the same completing filter tokens as `select` — the log set to aggregate.
# `--by` groups the results (`by (...)`, completing; buckets like `_time:1h` or
# `status:100` pass through). Each aggregation is a flag taking a comma-list of
# fields, expanding to one function per field with an auto-named result column:
# `--sum`/`--avg`/`--min`/`--max`/`--median f` → `avg_f`…, `--count-uniq f` →
# `uniq_f`, `--p90`/`--p95`/`--p99 f` → `p99_f` (quantiles), and the fieldless
# `--count` → `count`. With no aggregation flag it counts rows. `--sort-by`
# (completing the RESULT columns) with `--desc`/`--limit` is server-side top-N.
#
# Output is WIDE by default — one row per group, one column per aggregation
# (`{host, count, avg_latency_ms}`), the SQL-GROUP-BY shape; `--long` keeps the
# tidy `{..by, metric, value}` rows instead (what `raw-stats` returns). Instant by
# default (at `--time`, else server now); `--range` returns a time series over the
# `--last` / `--start`/`--end` window at `--step` resolution (wide rows carry a
# leading `time`). Anything the flags can't express — a `count() if(...)`
# conditional, `values()`, an exotic quantile — is a job for `raw-stats`.
# `--dry-run` returns `{connection, query}` without running.
@category mole-victorialogs
@example "count rows per level (count is the default aggregation)" {
  mole-victorialogs stats --by level --dry-run | get query
} --result "* | stats by (level) count() as count"
@example "top 10 hosts by error volume" {
  mole-victorialogs stats level:error --by host --sort-by count --desc --limit 10 --dry-run | get query
} --result "level:error | stats by (host) count() as count | sort by (count) desc | limit 10"
@example "a latency profile per app" {
  mole-victorialogs stats --by app --avg latency_ms --p95 latency_ms --p99 latency_ms --dry-run | get query
} --result "* | stats by (app) avg(latency_ms) as avg_latency_ms, quantile(0.95, latency_ms) as p95_latency_ms, quantile(0.99, latency_ms) as p99_latency_ms"
@example "several fields through one aggregation" {
  mole-victorialogs stats --by host --sum bytes,latency_ms --dry-run | get query
} --result "* | stats by (host) sum(bytes) as sum_bytes, sum(latency_ms) as sum_latency_ms"
@example "distinct values in the last hour, no grouping" {
  mole-victorialogs stats --count-uniq host --last 1hr --dry-run | get query
} --result "* | stats count_uniq(host) as uniq_host"
@example "an hourly error time series" {
  mole-victorialogs stats level:error --by level --range --last 1day --step 1hr
}
export def "stats" [
  ...filters: string@"vl-filter"                   # LogsQL filter tokens (AND-joined) — the log set to aggregate
  --by(-g): string@"vl-fields-csv"                 # group-by fields, comma-separated → `by (...)` (buckets ok: `_time:1h`)
  --count(-C)                                      # count() → `count` (the default when no aggregation is given)
  --count-uniq: string@"vl-fields-csv"             # count_uniq(f) per field → `uniq_<f>`
  --sum: string@"vl-fields-csv"                    # sum(f) per field → `sum_<f>`
  --avg: string@"vl-fields-csv"                    # avg(f) per field → `avg_<f>`
  --min: string@"vl-fields-csv"                    # min(f) per field → `min_<f>`
  --max: string@"vl-fields-csv"                    # max(f) per field → `max_<f>`
  --median: string@"vl-fields-csv"                 # median(f) per field → `median_<f>`
  --p90: string@"vl-fields-csv"                    # quantile(0.9, f) per field → `p90_<f>`
  --p95: string@"vl-fields-csv"                    # quantile(0.95, f) per field → `p95_<f>`
  --p99: string@"vl-fields-csv"                    # quantile(0.99, f) per field → `p99_<f>`
  --sort-by(-s): string@"vl-stat-cols"             # post-stats sort over RESULT columns → `| sort by (...)`
  --desc(-d)                                       # sort descending (default: ascending)
  --limit(-l): int                                 # post-stats `| limit N` (server-side top-N)
  --range(-r)                                       # time series instead of a single instant
  --time(-t): datetime                             # instant to evaluate at (default: server now)
  --last(-L): duration                             # window ending now (shorthand for --start (now - dur))
  --start(-a): datetime                            # window start (overrides --last)
  --end(-b): datetime                              # window end (default: now when --last is given)
  --step: duration = 1hr                           # series step (with --range)
  --long                                           # keep tidy {..by, metric, value} rows (skip the wide pivot)
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string                                    # override the connection URL
  --token: string                                  # override the bearer token
  --set: record = {}                               # override any other connection field(s)
  --dry-run(-n)                                     # return {connection, query} instead of running
] {
  let conf = (vl-conf $connection $url $token $set)
  let filter = (vl-compose-filter $filters)
  let by = (vl-csv $by)
  let aggs = (vl-aggs $count $count_uniq $sum $avg $min $max $median $p90 $p95 $p99)
  let q = (logsql build-stats $filter --aggs $aggs --by $by
    --sort-by (vl-csv $sort_by) --desc=$desc --limit $limit)
  if $dry_run { return {connection: ($conf | conn redact), query: $q} }
  # Instant vs range: same endpoints/shapers as raw-stats, then pivot long→wide
  # (unless --long) keyed on the by-fields (+ time for a range series).
  let tidy = if $range {
    let r = (vl-range $last $start $end)
    (client stats-query-range $conf $q
      --start (logsql vl-time $r.start) --end (logsql vl-time $r.end) --step (logsql step $step))
    | logsql stats-range $in
  } else {
    (client stats-query $conf $q --time (logsql vl-time $time)) | logsql stats $in
  }
  if $long { return $tidy }
  # Bucket syntax in --by (`_time:1h`) labels the response column by the bare
  # field, so strip the `:bucket` suffix when naming the pivot's key columns.
  let labels = ($by | each {|b| $b | split row ":" | first | str trim })
  let keys = (if $range { ["time"] ++ $labels } else { $labels })
  logsql stats-wide $tidy --keys $keys --cols ($aggs | get name)
}

# List the field names present in a query's results, with hit counts.
#
# Returns a `{value, hits}` table. Like `select`, the log set is composed from
# `...filters` — LogsQL filter tokens (`level:error`, `status:>=500`) AND-joined
# and tab-completing field → value (a raw regex/`OR` filter is just a quoted
# token); no filters means every field. The window scopes the lookup.
@category mole-victorialogs
@example "all field names" { mole-victorialogs fields }
@example "field names among errors in the last hour" { mole-victorialogs fields level:error --last 1hr }
@example "inspect the composed filter without running" { mole-victorialogs fields level:error --dry-run | get query } --result "level:error"
export def "fields" [
  ...filters: string@"vl-filter"                   # LogsQL filter tokens (AND-joined): error  level:error  status:>=500
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
  --dry-run(-n)                                    # return {connection, query} instead of running
] {
  let conf = (vl-conf $connection $url $token $set)
  let filter = (vl-compose-filter $filters)
  if $dry_run { return {connection: ($conf | conn redact), query: $filter} }
  let range = (vl-range $last $start $end)
  (client field-names $conf $filter
    --start (logsql vl-time $range.start) --end (logsql vl-time $range.end))
  | logsql values $in
}

# List the distinct values of a field, with hit counts.
#
# Returns a `{value, hits}` table for <field>. Like `select`, the log set is
# composed from `...filters` (AND-joined, tab-completing filter tokens); `--limit`
# caps the number of values and the window scopes the lookup. (Named
# `field-values`, not `values` — `values` is a Nushell builtin.)
@category mole-victorialogs
@example "every level value" { mole-victorialogs field-values level }
@example "top hosts among errors" { mole-victorialogs field-values host level:error --limit 20 }
@example "inspect the composed filter without running" { mole-victorialogs field-values host level:error --dry-run | get query } --result "level:error"
export def "field-values" [
  field: string@"vl-field"                         # the field name to enumerate
  ...filters: string@"vl-filter"                   # LogsQL filter tokens (AND-joined): error  level:error  status:>=500
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --limit(-l): int                                 # max number of values to return
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
  --dry-run(-n)                                    # return {connection, query} instead of running
] {
  let conf = (vl-conf $connection $url $token $set)
  let filter = (vl-compose-filter $filters)
  if $dry_run { return {connection: ($conf | conn redact), query: $filter} }
  let range = (vl-range $last $start $end)
  (client field-values $conf $filter $field
    --start (logsql vl-time $range.start) --end (logsql vl-time $range.end) --limit $limit)
  | logsql values $in
}

# List the log streams matching a query, with hit counts.
#
# Returns a `{value, hits}` table where each `value` is a stream selector string
# like `{host="h1",app="foo"}`. Like `select`, the log set is composed from
# `...filters` (AND-joined, tab-completing filter tokens); `--limit` caps the
# number of streams and the window scopes the lookup.
@category mole-victorialogs
@example "all active streams" { mole-victorialogs streams }
@example "streams carrying errors, last day" { mole-victorialogs streams level:error --last 1day --limit 50 }
@example "inspect the composed filter without running" { mole-victorialogs streams level:error --dry-run | get query } --result "level:error"
export def "streams" [
  ...filters: string@"vl-filter"                   # LogsQL filter tokens (AND-joined): error  level:error  status:>=500
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --limit(-l): int                                 # max number of streams to return
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
  --dry-run(-n)                                    # return {connection, query} instead of running
] {
  let conf = (vl-conf $connection $url $token $set)
  let filter = (vl-compose-filter $filters)
  if $dry_run { return {connection: ($conf | conn redact), query: $filter} }
  let range = (vl-range $last $start $end)
  (client streams $conf $filter
    --start (logsql vl-time $range.start) --end (logsql vl-time $range.end) --limit $limit)
  | logsql values $in
}

# The most frequent values of every field, grouped by field.
#
# Returns `{field, values}` rows, where `values` is a `{value, hits}` table of the
# top values for that field. Like `select`, the log set is composed from
# `...filters` (AND-joined, tab-completing filter tokens); `--limit` caps the
# values kept per field and the window scopes the lookup.
@category mole-victorialogs
@example "the facet breakdown of the last hour" { mole-victorialogs facets --last 1hr }
@example "facets among errors, 10 values per field" { mole-victorialogs facets level:error --limit 10 }
@example "inspect the composed filter without running" { mole-victorialogs facets level:error --dry-run | get query } --result "level:error"
export def "facets" [
  ...filters: string@"vl-filter"                   # LogsQL filter tokens (AND-joined): error  level:error  status:>=500
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --limit(-l): int                                 # max values kept per field
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
  --dry-run(-n)                                    # return {connection, query} instead of running
] {
  let conf = (vl-conf $connection $url $token $set)
  let filter = (vl-compose-filter $filters)
  if $dry_run { return {connection: ($conf | conn redact), query: $filter} }
  let range = (vl-range $last $start $end)
  (client facets $conf $filter
    --start (logsql vl-time $range.start) --end (logsql vl-time $range.end) --limit $limit)
  | logsql facets $in
}

# Make a victorialogs connection the current one for this driver.
#
# Records the choice in `$env.MOLE_CURRENT.victorialogs`, so later verbs can omit
# `--connection`. Validates that `name` exists and is a victorialogs connection.
# Also warms the completion catalog (field names) for the connection, best-effort
# — so tab-completion is ready right away.
@category mole-victorialogs
@example "make the prod connection current" { mole-victorialogs set-connection prod }
export def --env "set-connection" [
  name: string@complete-connection               # a victorialogs connection name (from the connections file)
]: nothing -> nothing {
  let conf = (conn set-current victorialogs $name)
  try { vl-catalog-load $conf --refresh | ignore } catch { }
}
