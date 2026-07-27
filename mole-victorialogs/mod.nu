# mole-victorialogs — VictoriaLogs driver plugin (READ-ONLY LogsQL HTTP API).
#
# A PLUGIN (data source): supports the `victorialogs` driver, registers itself as
# a driver, and exposes read-only verbs — `query` / `hits` / `stats` / `fields` /
# `field-values` / `streams` / `facets` / `set-connection`. It talks to
# VictoriaLogs over its HTTP API using Nushell's built-in `http` (no external
# CLI), so `requires: []` in mole.nuon.
#
# LAYERING (two files, like mole-prometheus's client+wrapper split):
#   - client.nu  — HAND-WRITTEN, mechanical HTTP layer for the read-only
#                  `/select/logsql/` POST endpoints: base URL, multi-tenancy +
#                  auth headers, form-urlencoding, timeouts, non-2xx raising. It
#                  returns lightly-parsed data (raw JSONL text for `query`, a
#                  `from json` record otherwise). Hand-written, not generated,
#                  because VictoriaLogs ships no OpenAPI spec and its endpoints
#                  are POST form-urlencoded (see client.nu header).
#   - logsql.nu  — PURE response→typed-rows transforms (JSONL→table with `_time`
#                  a datetime, hits pivot, Prometheus-shaped stats shaping,
#                  value/facets parsing) plus the time/duration formatting
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

const HERE = (path self | path dirname)

export-env {
  let m = (open ([$HERE mole.nuon] | path join))
  $env.MOLE_REGISTRY = (($env.MOLE_REGISTRY? | default {}) | upsert $m.driver $m)
  $env.MOLE_CURRENT = ($env.MOLE_CURRENT? | default {})
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

# The cached catalog for whatever connection the command line names (or the
# current one). Cache-only — never hits the network, so completers stay instant.
def vl-catalog-ctx [context: string]: nothing -> record {
  try {
    let conf = (vl-conf (vl-flag $context ["--connection" "-c"]) null null {})
    (cache read (cache path "victorialogs" ($conf | get -o name | default "_"))) | default {}
  } catch { {} }
}

def "vl-field" [context: string]: nothing -> list<string> { vl-catalog-ctx $context | get -o fields | default [] }

# ---- user verbs ---------------------------------------------------------------

# Run a LogsQL query, returning one typed row per matching log entry.
#
# The expression is the positional <expr>, a saved `--file` (resolved under the
# query dir with a `.logsql` suffix), or `$EDITOR` when neither is given. Each row
# is a log entry — every field a column, with `_time` coerced to a datetime and
# all other fields kept as the strings VictoriaLogs returned. The window is
# `--last` (now minus a duration) or explicit `--start`/`--end`; `--limit` caps
# the number of latest entries and `--offset` paginates. `--raw` skips the `_time`
# coercion. Connection is the current victorialogs one unless `--connection` names
# another; `--url`/`--token`/`--set` override fields.
@category mole-victorialogs
@example "the last hour of errors" { mole-victorialogs query 'level:error' --last 1hr --limit 100 }
@example "an explicit window" { mole-victorialogs query '*' --start 2026-07-26T00:00:00Z --end 2026-07-26T06:00:00Z }
@example "a saved query against a named connection" { mole-victorialogs query --file dashboards/errors.logsql -c prod }
@example "query text piped via stdin" { mole query show dashboards/errors.logsql | mole-victorialogs query -c prod }
export def "query" [
  expr?: string                                    # LogsQL expression (else --file, else stdin, else $EDITOR)
  --file(-f): string@"complete queryfile"          # saved query file (relative to the query dir)
  --last(-L): duration                             # window ending now (shorthand for --start (now - dur))
  --start(-a): datetime                            # window start (overrides --last)
  --end(-b): datetime                              # window end (default: now when --last is given)
  --limit(-l): int                                 # return up to N latest entries
  --offset(-o): int                                # skip N entries (pagination)
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string                                    # override the connection URL
  --token: string                                  # override the bearer token
  --set: record = {}                               # override any other connection field(s)
  --raw(-R)                                         # skip the _time datetime coercion
] {
  let conf = (vl-conf $connection $url $token $set)
  let q = ($in | query resolve $expr --file $file --suffix ".logsql")
  let range = (vl-range $last $start $end)
  let body = (client query $conf $q
    --start (logsql vl-time $range.start) --end (logsql vl-time $range.end) --limit $limit --offset $offset)
  vl-warm $conf
  if $raw { logsql jsonl $body } else { logsql query $body }
}

# Per-bucket hit counts over time. Returns tidy `{time, <group>, hits}` rows.
#
# The <expr> is the LogsQL filter (default `*`). `--step` sets the bucket width
# (server default is auto); `--field` groups the counts by that field's values, so
# each row carries the group columns. The window is `--last` or `--start`/`--end`.
@category mole-victorialogs
@example "hourly error counts over a day" { mole-victorialogs hits 'level:error' --last 1day --step 1hr }
@example "counts grouped by level" { mole-victorialogs hits '*' --last 6hr --step 30min --field level }
export def "hits" [
  expr?: string                                    # LogsQL filter (default: *)
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --step(-s): duration                             # bucket width (default: server auto)
  --field(-F): string@"vl-field"                   # group counts by this field's values
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
] {
  let conf = (vl-conf $connection $url $token $set)
  let range = (vl-range $last $start $end)
  (client hits $conf ($expr | default "*")
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
@example "instant counts by level" { mole-victorialogs stats 'error | stats count() by (level)' }
@example "a daily time series" { mole-victorialogs stats '* | stats count() by (level)' --range --last 1day --step 1hr }
export def "stats" [
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

# List the field names present in the results of a query, with hit counts.
#
# Returns a `{value, hits}` table. The <expr> is the LogsQL filter (default `*`);
# the window scopes the lookup.
@category mole-victorialogs
@example "all field names" { mole-victorialogs fields }
@example "field names among errors in the last hour" { mole-victorialogs fields 'level:error' --last 1hr }
export def "fields" [
  expr?: string                                    # LogsQL filter (default: *)
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
] {
  let conf = (vl-conf $connection $url $token $set)
  let range = (vl-range $last $start $end)
  (client field-names $conf ($expr | default "*")
    --start (logsql vl-time $range.start) --end (logsql vl-time $range.end))
  | logsql values $in
}

# List the distinct values of a field, with hit counts.
#
# Returns a `{value, hits}` table for <field>. The <expr> is the LogsQL filter
# (default `*`); `--limit` caps the number of values, and the window scopes the
# lookup. (Named `field-values`, not `values` — `values` is a Nushell builtin.)
@category mole-victorialogs
@example "every level value" { mole-victorialogs field-values level }
@example "top hosts among errors" { mole-victorialogs field-values host 'level:error' --limit 20 }
export def "field-values" [
  field: string@"vl-field"                         # the field name to enumerate
  expr?: string                                    # LogsQL filter (default: *)
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --limit(-l): int                                 # max number of values to return
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
] {
  let conf = (vl-conf $connection $url $token $set)
  let range = (vl-range $last $start $end)
  (client field-values $conf ($expr | default "*") $field
    --start (logsql vl-time $range.start) --end (logsql vl-time $range.end) --limit $limit)
  | logsql values $in
}

# List the log streams matching a query, with hit counts.
#
# Returns a `{value, hits}` table where each `value` is a stream selector string
# like `{host="h1",app="foo"}`. The <expr> is the LogsQL filter (default `*`);
# `--limit` caps the number of streams, and the window scopes the lookup.
@category mole-victorialogs
@example "all active streams" { mole-victorialogs streams }
@example "streams carrying errors, last day" { mole-victorialogs streams 'level:error' --last 1day --limit 50 }
export def "streams" [
  expr?: string                                    # LogsQL filter (default: *)
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --limit(-l): int                                 # max number of streams to return
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
] {
  let conf = (vl-conf $connection $url $token $set)
  let range = (vl-range $last $start $end)
  (client streams $conf ($expr | default "*")
    --start (logsql vl-time $range.start) --end (logsql vl-time $range.end) --limit $limit)
  | logsql values $in
}

# The most frequent values of every field, grouped by field.
#
# Returns `{field, values}` rows, where `values` is a `{value, hits}` table of the
# top values for that field. The <expr> is the LogsQL filter (default `*`);
# `--limit` caps the values kept per field, and the window scopes the lookup.
@category mole-victorialogs
@example "the facet breakdown of the last hour" { mole-victorialogs facets --last 1hr }
@example "facets among errors, 10 values per field" { mole-victorialogs facets 'level:error' --limit 10 }
export def "facets" [
  expr?: string                                    # LogsQL filter (default: *)
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --limit(-l): int                                 # max values kept per field
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
] {
  let conf = (vl-conf $connection $url $token $set)
  let range = (vl-range $last $start $end)
  (client facets $conf ($expr | default "*")
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
  let conf = (conn resolve $name --driver victorialogs)
  $env.MOLE_CURRENT = (($env.MOLE_CURRENT? | default {}) | upsert victorialogs $name)
  try { vl-catalog-load $conf --refresh | ignore } catch { }
}
