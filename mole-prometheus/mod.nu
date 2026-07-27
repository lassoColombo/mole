# mole-prometheus — Prometheus driver plugin (READ-ONLY HTTP API).
#
# A PLUGIN (data source): supports the `prometheus` driver, registers itself as a
# driver, and exposes read-only verbs — `query` / `query-range` / `series` /
# `labels` / `label-values` / `metrics`. It talks to Prometheus over its HTTP API
# using Nushell's built-in `http` (no external CLI), so `requires: []` in
# mole.nuon.
#
# LAYERING (two files, like the old client+wrapper split):
#   - client.nu  — GENERATED, do not edit. A lean, typed HTTP client for the
#                  read-only GET endpoints, produced from Prometheus's official
#                  OpenAPI 3.1 spec by `regen.nu`. It owns the mechanical parts:
#                  URL building, RFC-3986 encoding, auth, TLS, timeouts. Its query
#                  commands return the raw `{status, data, ...}` envelope with
#                  `data` untyped (the spec types the polymorphic result as `any`).
#   - mod.nu     — THIS wrapper. It owns policy: connection resolution, PromQL /
#                  time-range ergonomics, turning the polymorphic result into
#                  typed rows (vector/matrix/scalar → {..labels, value, timestamp}),
#                  and the completion catalog. Read-only is structural: the client
#                  is GET-only by construction, so there is no danger prompt.
#
# The generated client is imported PRIVATELY (`use ./client.nu`), so its
# `client query list`, `client series get`, … never leak into `use mole-prometheus`.

use mole/lib/conn.nu

# Driver-scoped connection completer: only THIS driver (prometheus), never other drivers.
def "complete-connection" []: nothing -> list<string> { conn names "prometheus" }
use mole/lib/cache.nu
use mole/lib/query.nu
use mole/lib/complete.nu
use ./client.nu
use mole-promql/promql.nu

const HERE = (path self | path dirname)

export-env {
  let m = (open ([$HERE mole.nuon] | path join))
  $env.MOLE_REGISTRY = (($env.MOLE_REGISTRY? | default {}) | upsert $m.driver $m)
  $env.MOLE_CURRENT = ($env.MOLE_CURRENT? | default {})
}

# ---- connection resolution ----------------------------------------------------

# Resolve a prometheus connection (named, or the current one) and apply ad-hoc
# `--url`/`--token`/`--set` overrides. Null overrides are dropped (see `conn
# override`), so unset flags are no-ops. Asserts the connection is a prometheus one.
def pq-conf [connection: any, url: any, token: any, set: record]: nothing -> record {
  conn with prometheus $connection ({url: $url, token: $token} | merge $set)
}

# The API base for the client's `--base-url`: the connection URL + `/api/v1`.
# Defaults to a local Prometheus when the connection carries no URL.
def pq-base [conf: record]: nothing -> string {
  let u = ($conf | get -o url | default "http://localhost:9090" | str trim --right --char '/')
  $"($u)/api/v1"
}

def pq-token [conf: record]: nothing -> string { $conf | get -o token | default "" }
def pq-insecure [conf: record]: nothing -> bool { $conf | get -o insecure | default false }

# ---- time range ---------------------------------------------------------------
# `promql resolve-range` owns the --last/--start/--end logic (pure); the plugin
# injects the clock, so `promql resolve-range $last $start $end (date now)` is the
# only place range resolution reads the wall clock.

# ---- completion catalog (metric & label names) --------------------------------

# Load the completion catalog for a connection: {meta, metrics, labels}. Cached
# for a day. `--refresh` rebuilds; otherwise a fresh cache is returned as-is. The
# catalog calls are short-timeout and only power tab-completion.
def pq-catalog-load [conf: record, --refresh]: nothing -> record {
  let file = (cache path "prometheus" ($conf | get -o name | default "_"))
  if (not $refresh) and (not (cache stale $file 1day)) { return (cache read $file) }
  let base = (pq-base $conf)
  let tok = (pq-token $conf)
  let ins = (pq-insecure $conf)
  let metrics = (client label-values get "__name__" --base-url $base --token $tok --insecure=$ins --max-time 10sec | get -o data | default [])
  let labels = (client labels get --base-url $base --token $tok --insecure=$ins --max-time 10sec | get -o data | default [])
  let data = {meta: {connection: ($conf | get -o name), driver: "prometheus", refreshed_at: (date now)}, metrics: $metrics, labels: $labels}
  $data | cache write $file
  $data
}

# Warm the catalog after a successful query, but only when it is cold (missing).
# Best-effort: the connection is known reachable here, so this is cheap and never
# breaks the calling command. `set-connection` is the explicit refresh point.
def pq-warm [conf: record]: nothing -> nothing {
  let file = (cache path "prometheus" ($conf | get -o name | default "_"))
  if (cache read $file | is-not-empty) { return }
  try { pq-catalog-load $conf | ignore } catch { }
}

# Resolve a connection FOR COMPLETION — by the `-c` on the line, else the current
# one — WITHOUT the `--driver` assertion. Completion runs in an environment that
# does NOT carry the self-assembled `$env.MOLE_REGISTRY`, so `conn with prometheus`
# (which asserts the connection's `driver` is `prometheus`) would
# throw; a bare `conn resolve <name>` only needs the config file. Returns the
# connection record, or null when no connection can be determined.
# State file mirroring the current connection name, so completion can find it
# without the session `$env` (completion may not carry `$env.MOLE_CURRENT`).
# Written by `set-connection`.
def pq-current-file []: nothing -> string { cache path "prometheus" "__current__" }

def pq-conf-complete [context: string]: nothing -> any {
  let named = (promql parse-flag $context ["--connection" "-c"])
  let cur = ($env.MOLE_CURRENT? | default {} | get -o prometheus)
  let filed = (cache read (pq-current-file) | get -o name)
  let name = ([$named $cur $filed] | where {|x| $x | is-not-empty } | get -o 0)
  if ($name | is-empty) { return null }
  try { conn resolve $name } catch { null }
}

# The cached catalog for whatever connection the command line names (or the
# current one). Cache-only — never hits the network, so completers stay instant.
def pq-catalog-ctx [context: string]: nothing -> record {
  let conf = (pq-conf-complete $context)
  if ($conf | is-empty) { return {} }
  (cache read (cache path "prometheus" ($conf | get -o name | default "_"))) | default {}
}

def "pq-metric" [context: string]: nothing -> list<string> { pq-catalog-ctx $context | get -o metrics | default [] }
def "pq-label" [context: string]: nothing -> list<string> { pq-catalog-ctx $context | get -o labels | default [] }
# PromQL is a full expression; the best cheap suggestion is a metric name to start.
def "pq-expr" [context: string]: nothing -> list<string> { pq-metric $context }
# A series selector usually starts with a metric name.
def "pq-selector" [context: string]: nothing -> list<string> { pq-metric $context }

# Static PromQL function / aggregation / range-window completers (no server call);
# the base vocab lives in the library. Prometheus is plain PromQL — no extras.
def "pq-func" [context: string]: nothing -> list<string> { promql funcs }
def "pq-agg" [context: string]: nothing -> list<string> { promql aggs }
def "pq-window" [context: string]: nothing -> list<string> { promql windows }

# Metric-scoped label NAMES for completion: a live `/labels?match[]=<metric>`
# (short timeout), falling back to the cached global label names. Silent on failure.
def "pq-mlabel" [context: string]: nothing -> list<string> {
  let cached = (pq-catalog-ctx $context | get -o labels | default [])
  let metric = (promql metric-arg $context)
  let conf = (pq-conf-complete $context)
  if ($metric | is-empty) or ($conf | is-empty) { return $cached }
  try {
    let live = (client labels get --qp-match [$metric]
      --base-url (pq-base $conf) --token (pq-token $conf) --insecure=(pq-insecure $conf) --max-time 3sec
      | get -o data | default [])
    if ($live | is-empty) { $cached } else { $live }
  } catch { $cached }
}

# Context-aware `label=value` matcher completion (models the old vlogs-eq). Before
# the `=`: metric-scoped label names, each with `=` appended. After the `=`: that
# label's live values (scoped to the metric, short timeout), as `label=value`.
# Silent on failure so a Tab never hangs the REPL.
def "pq-eq" [context: string]: nothing -> list<string> {
  let raw = ($context | str trim | split row --regex '\s+' | last | default "")
  let bare = ($raw | str replace --regex '^\[' '' | str replace --regex '^"' '')
  if ($bare | str contains "=") {
    let label = ($bare | split row --number 2 "=" | first)
    let metric = (promql metric-arg $context)
    let conf = (pq-conf-complete $context)
    if ($conf | is-empty) { return [] }
    try {
      let m = if ($metric | is-empty) { [] } else { [$metric] }
      (client label-values get $label --qp-match $m
        --base-url (pq-base $conf) --token (pq-token $conf) --insecure=(pq-insecure $conf) --max-time 3sec
      | get -o data | default [] | each {|v| $label + "=" + $v })
    } catch { [] }
  } else {
    (pq-mlabel $context) | each {|l| $l + "=" }
  }
}

# ---- user verbs ---------------------------------------------------------------

# Run an instant PromQL query, returning typed rows.
#
# The expression is the positional <expr>, a saved `--file` (resolved under the
# query dir with a `.promql` suffix), or `$EDITOR` when neither is given. A
# `vector` result comes back as one row per series — every label a column
# (`__name__` surfaced as `metric`), plus a `value` (float) and `timestamp`
# (datetime); a `scalar`/`string` result is a single {timestamp, value} row.
# `--raw` returns the API's `data` payload untyped; `--full` returns the entire
# `{status, data, warnings, …}` envelope. Connection is the current prometheus one
# unless `--connection` names another; `--url`/`--token`/`--set` override fields.
@category mole-prometheus
@example "instant value of a metric" { mole-prometheus query "up" }
@example "an aggregation, at a specific instant" { mole-prometheus query "sum by (job) (up)" --time 2026-07-26T00:00:00Z }
@example "a saved query against a named connection" { mole-prometheus query --file dashboards/errors.promql -c prod }
@example "query text piped via stdin" { mole query show dashboards/errors.promql | mole-prometheus query -c prod }
export def "query" [
  expr?: string@"pq-expr"                          # PromQL expression (else --file, else stdin, else $EDITOR)
  --file(-f): string@"complete queryfile"          # saved query file (relative to the query dir)
  --time(-t): datetime                             # evaluation instant (default: server now)
  --limit(-l): int                                 # max number of series to return
  --timeout: string                                # per-query evaluation timeout (e.g. "30s")
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string                                    # override the connection URL
  --token: string                                  # override the bearer token
  --set: record = {}                               # override any other connection field(s)
  --raw(-R)                                         # return the API `data` payload, untyped
  --full(-F)                                        # return the whole {status, data, warnings, …} envelope
] {
  let conf = (pq-conf $connection $url $token $set)
  let q = ($in | query resolve $expr --file $file --suffix ".promql")
  let resp = (client query list --query $q --time (promql ts $time) --limit $limit --timeout $timeout
    --base-url (pq-base $conf) --token (pq-token $conf) --insecure=(pq-insecure $conf))
  pq-warm $conf
  if $full { return $resp }
  let data = ($resp | get -o data)
  if $raw { $data } else { promql normalize $data }
}

# Run a range PromQL query over a time window, returning a tidy time series.
#
# Same expression sources as `query`. The window is `--last` (now minus a
# duration), or explicit `--start`/`--end`; `--step` is the resolution (default
# 15s). A `matrix` result comes back tidy: one row per (series, point), every
# label a column (`__name__` as `metric`), plus `timestamp` (datetime) and `value`
# (float). `--raw`/`--full` and the connection flags behave as in `query`.
@category mole-prometheus
@example "last hour of a rate, at 1-minute resolution" { mole-prometheus query-range "rate(http_requests_total[5m])" --last 1hr --step 1min }
@example "an explicit window" { mole-prometheus query-range "up" --start 2026-07-26T00:00:00Z --end 2026-07-26T06:00:00Z --step 5min }
export def "query-range" [
  expr?: string@"pq-expr"                          # PromQL expression (else --file, else stdin, else $EDITOR)
  --file(-f): string@"complete queryfile"          # saved query file (relative to the query dir)
  --last(-L): duration                             # window ending now (shorthand for --start (now - dur))
  --start(-a): datetime                            # window start (overrides --last)
  --end(-b): datetime                              # window end (default: now when --last is given)
  --step(-s): duration = 15sec                     # query resolution step
  --limit(-l): int                                 # max number of series to return
  --timeout: string                                # per-query evaluation timeout (e.g. "30s")
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string                                    # override the connection URL
  --token: string                                  # override the bearer token
  --set: record = {}                               # override any other connection field(s)
  --raw(-R)                                         # return the API `data` payload, untyped
  --full(-F)                                        # return the whole {status, data, warnings, …} envelope
] {
  let conf = (pq-conf $connection $url $token $set)
  let q = ($in | query resolve $expr --file $file --suffix ".promql")
  let range = (promql resolve-range $last $start $end (date now))
  if ($range.start | is-empty) { error make {msg: "query-range needs a window: pass --last, or --start/--end"} }
  let resp = (client query-range list --query $q
    --start (promql ts $range.start) --end (promql ts $range.end) --step (promql step $step)
    --limit $limit --timeout $timeout
    --base-url (pq-base $conf) --token (pq-token $conf) --insecure=(pq-insecure $conf))
  pq-warm $conf
  if $full { return $resp }
  let data = ($resp | get -o data)
  if $raw { $data } else { promql normalize $data }
}

# Compose and run a PromQL query from completion-aware flags — the ergonomic
# alternative to writing raw PromQL in `query`.
#
# Assembles `[agg [by/without (labels)]] ( [func] ( metric{matchers}[range] ) )`
# from the flags, then runs it: INSTANT by default, or as a RANGE query when any
# of `--last`/`--start`/`--end` is given. `--dry-run` returns a `{connection, query}` record — the resolved
# connection (secrets dropped) and the assembled PromQL — without running. Completion is the point —
# `<metric>` completes from the catalog; `--eq`/`--ne`/`--re`/`--nre` complete the
# label name and, after `=`, that label's live values SCOPED TO THE METRIC;
# `--func`/`--agg` complete from the PromQL function/aggregation sets; `--by`/
# `--without` complete the metric's labels. Matcher tokens are `label=value` (the
# value is quoted for you); use `--re`/`--nre` for regex values. Results are typed
# exactly as `query`/`query-range`.
@category mole-prometheus
@example "filter a metric by labels (instant)" {
  mole-prometheus select http_requests_total --eq [job=api method=GET] --dry-run | get query
} --result 'http_requests_total{job="api", method="GET"}'
@example "a rate aggregated by job (range window applied at run time)" {
  mole-prometheus select http_requests_total --eq [job=api] --re [status=5..] --range 5m --func rate --agg sum --by [job] --last 1hr --step 1min --dry-run | get query
} --result 'sum by (job) (rate(http_requests_total{job="api", status=~"5.."}[5m]))'
@example "run it for real against a connection" {
  mole-prometheus select up --eq [job=prometheus] -c prometheus-local-dev
}
export def "select" [
  metric: string@"pq-metric"                       # metric name (completes from the catalog)
  --eq(-e): list<string>@"pq-eq"                   # equality matchers:   label=value → label="value"
  --ne: list<string>@"pq-eq"                       # inequality matchers: label=value → label!="value"
  --re: list<string>@"pq-eq"                       # regex matchers:      label=value → label=~"value"
  --nre: list<string>@"pq-eq"                      # negative-regex:      label=value → label!~"value"
  --range(-r): string@"pq-window"                  # range-vector window, e.g. 5m → [5m] (for rate/increase/…)
  --func: string@"pq-func"                         # wrap the selector in this function (rate, increase, …)
  --agg: string@"pq-agg"                           # aggregate with this operator (sum, avg, topk, …)
  --by: list<string>@"pq-mlabel"                   # aggregation grouping: by (labels) — needs --agg
  --without: list<string>@"pq-mlabel"              # aggregation grouping: without (labels) — needs --agg
  --time(-t): datetime                             # instant to evaluate at (default: server now)
  --last(-L): duration                             # range mode: window ending now
  --start(-a): datetime                            # range mode: window start
  --end(-b): datetime                              # range mode: window end
  --step(-s): duration = 15sec                     # range mode: resolution step
  --limit(-l): int                                 # max number of series to return
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string                                    # override the connection URL
  --token: string                                  # override the bearer token
  --set: record = {}                               # override any other connection field(s)
  --raw(-R)                                         # return the API `data` payload, untyped
  --full(-F)                                        # return the whole {status, data, …} envelope
  --dry-run(-n)                                    # return a {connection, query} record instead of running
] {
  if (($by | is-not-empty) or ($without | is-not-empty)) and ($agg | is-empty) {
    error make {msg: "select: --by/--without require --agg"}
  }
  if ($by | is-not-empty) and ($without | is-not-empty) {
    error make {msg: "select: --by and --without are mutually exclusive"}
  }
  let expr = (promql build $metric
    --matchers (promql matchers ($eq | default []) ($ne | default []) ($re | default []) ($nre | default []))
    --range ($range | default "")
    --func ($func | default "")
    --agg ($agg | default "")
    --by ($by | default [])
    --without ($without | default []))
  if $dry_run { return {connection: (pq-conf $connection $url $token $set | conn redact), query: $expr} }
  if (($last | is-not-empty) or ($start | is-not-empty) or ($end | is-not-empty)) {
    query-range $expr --last $last --start $start --end $end --step $step --limit $limit --connection $connection --url $url --token $token --set $set --raw=$raw --full=$full
  } else {
    query $expr --time $time --limit $limit --connection $connection --url $url --token $token --set $set --raw=$raw --full=$full
  }
}

# List the series matching one or more selectors.
#
# Each positional is a series selector (the `match[]` argument), e.g.
# `'up{job="api"}'`; at least one is required. Returns one row per series — a
# table of its label sets. The window (`--last` / `--start` / `--end`) is optional
# and scopes the lookup; omit it to search all time.
@category mole-prometheus
@example "series for a metric" { mole-prometheus series "up" }
@example "series across two selectors in the last day" { mole-prometheus series 'up{job="api"}' 'process_start_time_seconds' --last 1day }
export def "series" [
  ...match: string@"pq-selector"                   # series selector(s) — at least one required
  --last(-L): duration                             # scope to a window ending now
  --start(-a): datetime                            # window start
  --end(-b): datetime                              # window end
  --limit(-l): int                                 # max number of series to return
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string
  --token: string
  --set: record = {}
] {
  if ($match | is-empty) { error make {msg: "series: at least one selector is required"} }
  let conf = (pq-conf $connection $url $token $set)
  let range = (promql resolve-range $last $start $end (date now))
  (client series get --qp-match $match --start (promql ts $range.start) --end (promql ts $range.end) --limit $limit
    --base-url (pq-base $conf) --token (pq-token $conf) --insecure=(pq-insecure $conf))
  | get -o data | default []
  | each {|r| promql relabel $r }   # surface __name__ as `metric`, as query/query-range do
}

# List label names present in the data (optionally scoped by selectors/window).
@category mole-prometheus
@example "all label names" { mole-prometheus labels }
@example "label names used by a selector" { mole-prometheus labels --match ['up'] --last 1hr }
export def "labels" [
  --match(-m): list<string>@"pq-selector"          # series selector(s) to scope the label names
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --limit(-l): int
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
] {
  let conf = (pq-conf $connection $url $token $set)
  let range = (promql resolve-range $last $start $end (date now))
  (client labels get --qp-match $match --start (promql ts $range.start) --end (promql ts $range.end) --limit $limit
    --base-url (pq-base $conf) --token (pq-token $conf) --insecure=(pq-insecure $conf))
  | get -o data | default []
}

# List the distinct values of a label (optionally scoped by selectors/window).
@category mole-prometheus
@example "every job value" { mole-prometheus label-values job }
@example "instance values for one job" { mole-prometheus label-values instance --match ['up{job="api"}'] }
export def "label-values" [
  label: string@"pq-label"                         # the label name to enumerate
  --match(-m): list<string>@"pq-selector"          # series selector(s) to scope the values
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --limit(-l): int
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
] {
  let conf = (pq-conf $connection $url $token $set)
  let range = (promql resolve-range $last $start $end (date now))
  (client label-values get $label --qp-match $match --start (promql ts $range.start) --end (promql ts $range.end) --limit $limit
    --base-url (pq-base $conf) --token (pq-token $conf) --insecure=(pq-insecure $conf))
  | get -o data | default []
}

# The metric catalog: type, help text and unit per metric (from target metadata).
#
# Returns a {metric, type, help, unit} table. Pass a <metric> to filter to one.
@category mole-prometheus
@example "the whole catalog" { mole-prometheus metrics }
@example "metadata for one metric" { mole-prometheus metrics http_requests_total }
export def "metrics" [
  metric?: string@"pq-metric"                      # a metric name to filter metadata for
  --limit(-l): int                                 # max number of metrics
  --limit-per-metric: int                          # max metadata entries per metric
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
] {
  let conf = (pq-conf $connection $url $token $set)
  (client metadata get --metric $metric --limit $limit --limit-per-metric $limit_per_metric
    --base-url (pq-base $conf) --token (pq-token $conf) --insecure=(pq-insecure $conf))
  | get -o data | default {} | promql metadata $in
}

# Make a prometheus connection the current one for this driver.
#
# Records the choice in `$env.MOLE_CURRENT.prometheus`, so later verbs can omit
# `--connection`. Validates that `name` exists and is a prometheus connection.
# Also warms the completion catalog (metric & label names) for the connection,
# best-effort — so tab-completion is ready right away.
@category mole-prometheus
@example "make the prod connection current" { mole-prometheus set-connection prod }
export def --env "set-connection" [
  name: string@complete-connection               # a prometheus connection name (from the connections file)
]: nothing -> nothing {
  let conf = (conn resolve $name --driver prometheus)
  $env.MOLE_CURRENT = (($env.MOLE_CURRENT? | default {}) | upsert prometheus $name)
  {name: $name} | cache write (pq-current-file)   # so completion finds it without $env
  try { pq-catalog-load $conf --refresh | ignore } catch { }
}
