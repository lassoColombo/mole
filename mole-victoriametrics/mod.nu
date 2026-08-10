# mole-victoriametrics — VictoriaMetrics driver plugin (READ-ONLY HTTP API).
#
# A PLUGIN (data source): supports the `victoriametrics` driver, registers itself
# as a driver, and exposes read-only verbs — `raw-query` / `raw-query-range` / `series` /
# `labels` / `label-values` / `metrics`, plus two VictoriaMetrics-specific reads
# `tsdb-status` / `export-samples`. It talks to VictoriaMetrics over its
# Prometheus-compatible HTTP querying API using Nushell's built-in `http` (no
# external CLI), so `requires: []` in mole.nuon.
#
# CLOSE PORT OF mole-prometheus: VictoriaMetrics is Prometheus-querying-API
# compatible — same `/api/v1` endpoints, same request params, same response
# envelopes — so the verb shapes, result typing (promql.nu), and completion
# catalog are shared. The differences are: `driver` = `victoriametrics`,
# the default server port 8428 (single-node), the query language is MetricsQL (a
# PromQL superset, passed through as an opaque string), and the two VM-only reads.
#
# LAYERING (generated client + hand-written wrapper):
#   - client.nu  — GENERATED (from the vendored Prometheus OpenAPI spec by
#                  regen.nu), do not edit. A lean, typed HTTP client for the
#                  read-only GET endpoints; owns URL building, RFC-3986 encoding,
#                  auth, TLS, timeouts. Its query commands return the raw
#                  `{status, data, ...}` envelope with `data` untyped. regen.nu
#                  also appends the VM-specific `status-tsdb`/`export` GETs.
#   - mod.nu     — THIS wrapper. It owns policy: connection resolution, MetricsQL /
#                  time-range ergonomics, turning the polymorphic result into typed
#                  rows (vector/matrix/scalar → {..labels, value, timestamp}), and
#                  the completion catalog. Read-only is structural: the client is
#                  GET-only by construction, so there is no danger prompt.
#
# The generated client is imported PRIVATELY (`use ./client.nu`), so its
# `client query list`, `client series get`, … never leak into
# `use mole-victoriametrics`.

use mole/lib/conn.nu

# Driver-scoped connection completer: only THIS driver (victoriametrics), never other drivers.
def "complete-connection" []: nothing -> list<string> { conn names "victoriametrics" }
use mole/lib/cache.nu
use mole/lib/query.nu
use mole/lib/complete.nu
use ./client.nu
use ./promql.nu

const HERE = (path self | path dirname)

export-env {
  let m = (open ([$HERE mole.nuon] | path join))
  $env.MOLE_REGISTRY = (($env.MOLE_REGISTRY? | default {}) | upsert $m.driver $m)
  $env.MOLE_CURRENT = ($env.MOLE_CURRENT? | default {})
}

# ---- connection resolution ----------------------------------------------------

# Resolve a victoriametrics connection (named, or the current one) and apply
# ad-hoc `--url`/`--token`/`--set` overrides. Null overrides are dropped (see
# `conn override`), so unset flags are no-ops. Asserts the connection is a
# victoriametrics one.
def vm-conf [connection: any, url: any, token: any, set: record]: nothing -> record {
  conn with victoriametrics $connection ({url: $url, token: $token} | merge $set)
}

# The API base for the client's `--base-url`: the connection URL + `/api/v1`.
# Defaults to a local single-node VictoriaMetrics (port 8428) when the connection
# carries no URL.
def vm-base [conf: record]: nothing -> string {
  let u = ($conf | get -o url | default "http://localhost:8428" | str trim --right --char '/')
  $"($u)/api/v1"
}

def vm-token [conf: record]: nothing -> string { $conf | get -o token | default "" }
def vm-insecure [conf: record]: nothing -> bool { $conf | get -o insecure | default false }

# ---- time range ---------------------------------------------------------------
# `promql resolve-range` owns the --last/--start/--end logic (pure); the plugin
# injects the clock, so `promql resolve-range $last $start $end (date now)` is the
# only place range resolution reads the wall clock.

# ---- completion catalog (metric & label names) --------------------------------

# Load the completion catalog for a connection: {meta, metrics, labels}. Cached
# for a day. `--refresh` rebuilds; otherwise a fresh cache is returned as-is. The
# catalog calls are short-timeout and only power tab-completion.
def vm-catalog-load [conf: record, --refresh]: nothing -> record {
  let file = (cache path "victoriametrics" ($conf | get -o name | default "_"))
  if (not $refresh) and (not (cache stale $file 1day)) { return (cache read $file) }
  let base = (vm-base $conf)
  let tok = (vm-token $conf)
  let ins = (vm-insecure $conf)
  let metrics = (client label-values get "__name__" --base-url $base --token $tok --insecure=$ins --max-time 10sec | get -o data | default [])
  let labels = (client labels get --base-url $base --token $tok --insecure=$ins --max-time 10sec | get -o data | default [])
  let data = {meta: {connection: ($conf | get -o name), driver: "victoriametrics", refreshed_at: (date now)}, metrics: $metrics, labels: $labels}
  $data | cache write $file
  $data
}

# Warm the catalog after a successful query, but only when it is cold (missing).
# Best-effort: the connection is known reachable here, so this is cheap and never
# breaks the calling command. `set-connection` is the explicit refresh point.
def vm-warm [conf: record]: nothing -> nothing {
  let file = (cache path "victoriametrics" ($conf | get -o name | default "_"))
  if (cache read $file | is-not-empty) { return }
  try { vm-catalog-load $conf | ignore } catch { }
}

# Resolve a connection FOR COMPLETION — by the `-c` on the line, else the current
# one — WITHOUT the `--driver` assertion. Completion runs in an environment that
# does NOT carry the self-assembled `$env.MOLE_REGISTRY`, so `conn with
# victoriametrics` (which asserts the connection's `driver` is `victoriametrics`)
# would throw; a bare `conn resolve <name>` only needs the config
# file. A state file mirrors the current connection name so completion can find it
# without the session `$env` (completion may not carry `$env.MOLE_CURRENT`); it is
# written by `set-connection`. Returns the connection record, or null.
def vm-current-file []: nothing -> string { cache path "victoriametrics" "__current__" }

def vm-conf-complete [context: string]: nothing -> any {
  let named = (promql parse-flag $context ["--connection" "-c"])
  let cur = ($env.MOLE_CURRENT? | default {} | get -o victoriametrics)
  let filed = (cache read (vm-current-file) | get -o name)
  let name = ([$named $cur $filed] | where {|x| $x | is-not-empty } | get -o 0)
  if ($name | is-empty) { return null }
  try { conn resolve $name } catch { null }
}

# The cached catalog for whatever connection the command line names (or the
# current one). Cache-only — never hits the network, so completers stay instant.
def vm-catalog-ctx [context: string]: nothing -> record {
  let conf = (vm-conf-complete $context)
  if ($conf | is-empty) { return {} }
  (cache read (cache path "victoriametrics" ($conf | get -o name | default "_"))) | default {}
}

def "vm-metric" [context: string]: nothing -> list<string> { vm-catalog-ctx $context | get -o metrics | default [] }
def "vm-label" [context: string]: nothing -> list<string> { vm-catalog-ctx $context | get -o labels | default [] }
# MetricsQL is a full expression; the best cheap suggestion is a metric name to start.
def "vm-expr" [context: string]: nothing -> list<string> { vm-metric $context }
# A series selector usually starts with a metric name.
def "vm-selector" [context: string]: nothing -> list<string> { vm-metric $context }

# Static MetricsQL function / aggregation / range-window completers (no server
# call). MetricsQL is a PromQL SUPERSET: the base vocab comes from the library and
# VM's rollup/transform extras are injected via `++` — the peculiarity as a list.
def "vm-func" [context: string]: nothing -> list<string> {
  (promql funcs) ++ [
    rollup rollup_rate rollup_increase rollup_delta rollup_deriv rollup_scrape_interval
    range_avg range_sum range_min range_max range_median range_first range_last
    histogram_over_time share_le_over_time share_gt_over_time
    keep_last_value keep_next_value interpolate remove_resets running_sum running_avg
    ascent descent mode_over_time tmin_over_time tmax_over_time
  ]
}
def "vm-agg" [context: string]: nothing -> list<string> {
  (promql aggs) ++ [median mad limitk outliersk outliers_mad zscore any distinct]
}
def "vm-window" [context: string]: nothing -> list<string> { promql windows }

# Metric-scoped label NAMES for completion: a live `/labels?match[]=<metric>`
# (short timeout), falling back to the cached global label names. Silent on failure.
def "vm-mlabel" [context: string]: nothing -> list<string> {
  let cached = (vm-catalog-ctx $context | get -o labels | default [])
  let metric = (promql metric-arg $context)
  let conf = (vm-conf-complete $context)
  if ($metric | is-empty) or ($conf | is-empty) { return $cached }
  try {
    let live = (client labels get --qp-match [$metric]
      --base-url (vm-base $conf) --token (vm-token $conf) --insecure=(vm-insecure $conf) --max-time 3sec
      | get -o data | default [])
    if ($live | is-empty) { $cached } else { $live }
  } catch { $cached }
}

# Context-aware `label=value` matcher completion. Before the `=`: metric-scoped
# label names, each with `=` appended. After the `=`: that label's live values
# (scoped to the metric, short timeout), as `label=value`. Silent on failure so a
# Tab never hangs the REPL.
def "vm-eq" [context: string]: nothing -> list<string> {
  let raw = ($context | str trim | split row --regex '\s+' | last | default "")
  let bare = ($raw | str replace --regex '^\[' '' | str replace --regex '^"' '')
  if ($bare | str contains "=") {
    let label = ($bare | split row --number 2 "=" | first)
    let metric = (promql metric-arg $context)
    let conf = (vm-conf-complete $context)
    if ($conf | is-empty) { return [] }
    try {
      let m = if ($metric | is-empty) { [] } else { [$metric] }
      (client label-values get $label --qp-match $m
        --base-url (vm-base $conf) --token (vm-token $conf) --insecure=(vm-insecure $conf) --max-time 3sec
      | get -o data | default [] | each {|v| $label + "=" + $v })
    } catch { [] }
  } else {
    (vm-mlabel $context) | each {|l| $l + "=" }
  }
}

# ---- user verbs ---------------------------------------------------------------

# Run an instant MetricsQL query, returning typed rows.
#
# The expression is the positional <expr>, a saved `--file` (resolved under the
# query dir with a `.mql` suffix), or `$EDITOR` when neither is given. A `vector`
# result comes back as one row per series — every label a column (`__name__`
# surfaced as `metric`), plus a `value` (float) and `timestamp` (datetime); a
# `scalar`/`string` result is a single {timestamp, value} row. `--raw` returns the
# API's `data` payload untyped; `--full` returns the entire `{status, data,
# warnings, …}` envelope. Connection is the current victoriametrics one unless
# `--connection` names another; `--url`/`--token`/`--set` override fields.
#
# MetricsQL is a PromQL superset, so PromQL works unchanged; the expression is
# passed through as an opaque string.
@category mole-victoriametrics
@example "instant value of a metric" { mole-victoriametrics raw-query "up" }
@example "an aggregation, at a specific instant" { mole-victoriametrics raw-query "sum by (job) (up)" --time 2026-07-26T00:00:00Z }
@example "a saved query against a named connection" { mole-victoriametrics raw-query --file dashboards/errors.mql -c prod }
@example "query text piped via stdin" { mole query show dashboards/errors.mql | mole-victoriametrics raw-query -c prod }
export def "raw-query" [
  expr?: string@"vm-expr"                          # MetricsQL expression (else --file, else stdin, else $EDITOR)
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
  let conf = (vm-conf $connection $url $token $set)
  let q = ($in | query resolve $expr --file $file --suffix ".mql")
  let resp = (client query list --query $q --time (promql ts $time) --limit $limit --timeout $timeout
    --base-url (vm-base $conf) --token (vm-token $conf) --insecure=(vm-insecure $conf))
  vm-warm $conf
  if $full { return $resp }
  let data = ($resp | get -o data)
  if $raw { $data } else { promql normalize $data }
}

# Run a range MetricsQL query over a time window, returning a tidy time series.
#
# Same expression sources as `raw-query`. The window is `--last` (now minus a
# duration), or explicit `--start`/`--end`; `--step` is the resolution (default
# 15s). A `matrix` result comes back tidy: one row per (series, point), every
# label a column (`__name__` as `metric`), plus `timestamp` (datetime) and `value`
# (float). `--raw`/`--full` and the connection flags behave as in `raw-query`.
@category mole-victoriametrics
@example "last hour of a rate, at 1-minute resolution" { mole-victoriametrics raw-query-range "rate(http_requests_total[5m])" --last 1hr --step 1min }
@example "an explicit window" { mole-victoriametrics raw-query-range "up" --start 2026-07-26T00:00:00Z --end 2026-07-26T06:00:00Z --step 5min }
export def "raw-query-range" [
  expr?: string@"vm-expr"                          # MetricsQL expression (else --file, else stdin, else $EDITOR)
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
  let conf = (vm-conf $connection $url $token $set)
  let q = ($in | query resolve $expr --file $file --suffix ".mql")
  let range = (promql resolve-range $last $start $end (date now))
  if ($range.start | is-empty) { error make {msg: "raw-query-range needs a window: pass --last, or --start/--end"} }
  let resp = (client query-range list --query $q
    --start (promql ts $range.start) --end (promql ts $range.end) --step (promql step $step)
    --limit $limit --timeout $timeout
    --base-url (vm-base $conf) --token (vm-token $conf) --insecure=(vm-insecure $conf))
  vm-warm $conf
  if $full { return $resp }
  let data = ($resp | get -o data)
  if $raw { $data } else { promql normalize $data }
}

# Compose and run a MetricsQL query from completion-aware flags — the ergonomic
# alternative to writing raw MetricsQL in `raw-query`.
#
# Assembles `[agg [by/without (labels)]] ( [func] ( metric{matchers}[range] ) )`
# from the flags, then runs it: INSTANT by default, or as a RANGE query when any
# of `--last`/`--start`/`--end` is given. `--dry-run` returns a `{connection, query}` record — the resolved
# connection (secrets dropped) and the assembled MetricsQL — without running. Completion is the point —
# `<metric>` completes from the catalog; `--eq`/`--ne`/`--re`/`--nre` complete the
# label name and, after `=`, that label's live values SCOPED TO THE METRIC;
# `--func`/`--agg` complete from the MetricsQL function/aggregation sets (PromQL +
# VM extras); `--by`/`--without` complete the metric's labels. Matcher tokens are
# `label=value` (the value is quoted for you); use `--re`/`--nre` for regex values.
# Results are typed exactly as `raw-query`/`raw-query-range`.
@category mole-victoriametrics
@example "filter a metric by labels (instant)" {
  mole-victoriametrics select http_requests_total --eq [job=api method=GET] --dry-run | get query
} --result 'http_requests_total{job="api", method="GET"}'
@example "a rate aggregated by job (range window applied at run time)" {
  mole-victoriametrics select http_requests_total --eq [job=api] --re [status=5..] --range 5m --func rate --agg sum --by [job] --last 1hr --step 1min --dry-run | get query
} --result 'sum by (job) (rate(http_requests_total{job="api", status=~"5.."}[5m]))'
@example "run it for real against a connection" {
  mole-victoriametrics select up --eq [job=victoriametrics] -c victoriametrics-local-dev
}
export def "select" [
  metric: string@"vm-metric"                       # metric name (completes from the catalog)
  --eq(-e): list<string>@"vm-eq"                   # equality matchers:   label=value → label="value"
  --ne: list<string>@"vm-eq"                       # inequality matchers: label=value → label!="value"
  --re: list<string>@"vm-eq"                       # regex matchers:      label=value → label=~"value"
  --nre: list<string>@"vm-eq"                      # negative-regex:      label=value → label!~"value"
  --range(-r): string@"vm-window"                  # range-vector window, e.g. 5m → [5m] (for rate/increase/…)
  --func: string@"vm-func"                         # wrap the selector in this function (rate, rollup, …)
  --agg: string@"vm-agg"                           # aggregate with this operator (sum, avg, topk, …)
  --by: list<string>@"vm-mlabel"                   # aggregation grouping: by (labels) — needs --agg
  --without: list<string>@"vm-mlabel"              # aggregation grouping: without (labels) — needs --agg
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
  if $dry_run { return {connection: (vm-conf $connection $url $token $set | conn redact), query: $expr} }
  if (($last | is-not-empty) or ($start | is-not-empty) or ($end | is-not-empty)) {
    raw-query-range $expr --last $last --start $start --end $end --step $step --limit $limit --connection $connection --url $url --token $token --set $set --raw=$raw --full=$full
  } else {
    raw-query $expr --time $time --limit $limit --connection $connection --url $url --token $token --set $set --raw=$raw --full=$full
  }
}

# List the series matching one or more selectors.
#
# Each positional is a series selector (the `match[]` argument), e.g.
# `'up{job="api"}'`; at least one is required. Returns one row per series — a
# table of its label sets. The window (`--last` / `--start` / `--end`) is optional
# and scopes the lookup; omit it to search all time.
@category mole-victoriametrics
@example "series for a metric" { mole-victoriametrics series "up" }
@example "series across two selectors in the last day" { mole-victoriametrics series 'up{job="api"}' 'process_start_time_seconds' --last 1day }
export def "series" [
  ...match: string@"vm-selector"                   # series selector(s) — at least one required
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
  let conf = (vm-conf $connection $url $token $set)
  let range = (promql resolve-range $last $start $end (date now))
  (client series get --qp-match $match --start (promql ts $range.start) --end (promql ts $range.end) --limit $limit
    --base-url (vm-base $conf) --token (vm-token $conf) --insecure=(vm-insecure $conf))
  | get -o data | default []
  | each {|r| promql relabel $r }   # surface __name__ as `metric`, as raw-query/raw-query-range do
}

# List label names present in the data (optionally scoped by selectors/window).
@category mole-victoriametrics
@example "all label names" { mole-victoriametrics labels }
@example "label names used by a selector" { mole-victoriametrics labels --match ['up'] --last 1hr }
export def "labels" [
  --match(-m): list<string>@"vm-selector"          # series selector(s) to scope the label names
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --limit(-l): int
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
] {
  let conf = (vm-conf $connection $url $token $set)
  let range = (promql resolve-range $last $start $end (date now))
  (client labels get --qp-match $match --start (promql ts $range.start) --end (promql ts $range.end) --limit $limit
    --base-url (vm-base $conf) --token (vm-token $conf) --insecure=(vm-insecure $conf))
  | get -o data | default []
}

# List the distinct values of a label (optionally scoped by selectors/window).
@category mole-victoriametrics
@example "every job value" { mole-victoriametrics label-values job }
@example "instance values for one job" { mole-victoriametrics label-values instance --match ['up{job="api"}'] }
export def "label-values" [
  label: string@"vm-label"                         # the label name to enumerate
  --match(-m): list<string>@"vm-selector"          # series selector(s) to scope the values
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --limit(-l): int
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
] {
  let conf = (vm-conf $connection $url $token $set)
  let range = (promql resolve-range $last $start $end (date now))
  (client label-values get $label --qp-match $match --start (promql ts $range.start) --end (promql ts $range.end) --limit $limit
    --base-url (vm-base $conf) --token (vm-token $conf) --insecure=(vm-insecure $conf))
  | get -o data | default []
}

# The metric catalog: type, help text and unit per metric (from target metadata).
#
# Returns a {metric, type, help, unit} table. Pass a <metric> to filter to one.
# VictoriaMetrics implements the Prometheus /api/v1/metadata endpoint.
@category mole-victoriametrics
@example "the whole catalog" { mole-victoriametrics metrics }
@example "metadata for one metric" { mole-victoriametrics metrics http_requests_total }
export def "metrics" [
  metric?: string@"vm-metric"                      # a metric name to filter metadata for
  --limit(-l): int                                 # max number of metrics
  --limit-per-metric: int                          # max metadata entries per metric
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
] {
  let conf = (vm-conf $connection $url $token $set)
  (client metadata get --metric $metric --limit $limit --limit-per-metric $limit_per_metric
    --base-url (vm-base $conf) --token (vm-token $conf) --insecure=(vm-insecure $conf))
  | get -o data | default {} | promql metadata $in
}

# VictoriaMetrics TSDB status / cardinality stats (VM-specific read).
#
# Returns the parsed `data` of `/api/v1/status/tsdb`: series/label cardinality
# breakdowns (seriesCountByMetricName, labelValueCountByLabelName, …). Pass
# `--date YYYY-MM-DD` to scope to one day, `--topN` to cap each breakdown, and
# `--match` to scope by selector(s). `--raw` is a no-op alias for the default here
# (the payload is already a record); `--full` returns the whole envelope.
@category mole-victoriametrics
@example "overall cardinality stats" { mole-victoriametrics tsdb-status }
@example "top-5 series by metric name for a day" { mole-victoriametrics tsdb-status --date 2026-07-26 --topN 5 }
export def "tsdb-status" [
  --date: string                                   # day (YYYY-MM-DD) to report stats for
  --topN(-t): int                                  # cap each breakdown to N entries
  --match(-m): list<string>@"vm-selector"          # series selector(s) to scope the stats
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
  --full(-F)                                       # return the whole {status, data, …} envelope
] {
  let conf = (vm-conf $connection $url $token $set)
  let resp = (client status-tsdb get --date $date --topN $topN --match $match
    --base-url (vm-base $conf) --token (vm-token $conf) --insecure=(vm-insecure $conf))
  if $full { $resp } else { $resp | get -o data | default {} }
}

# Export raw samples for selectors as tidy rows (VM-specific read).
#
# Wraps `/api/v1/export`, which streams one JSON object per line
# ({metric, values, timestamps}) rather than the query envelope. Each positional
# is a `match[]` selector (at least one required). Returns tidy rows: one per
# (series, sample) — every label a column (`__name__` as `metric`), plus
# `timestamp` (datetime) and `value` (float). `--last`/`--start`/`--end` scope the
# time window. `--raw` returns the parsed JSONL objects untouched (columnar form).
@category mole-victoriametrics
@example "export a metric over the last hour" { mole-victoriametrics export-samples "up" --last 1hr }
@example "export two selectors, raw columnar form" { mole-victoriametrics export-samples 'up{job="api"}' 'process_cpu_seconds_total' --raw }
export def "export-samples" [
  ...match: string@"vm-selector"                   # series selector(s) — at least one required
  --last(-L): duration                             # scope to a window ending now
  --start(-a): datetime                            # window start
  --end(-b): datetime                              # window end
  --max-rows-per-line: int                         # max samples per JSON line
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
  --raw(-R)                                         # return the parsed JSONL objects (columnar), untidied
] {
  if ($match | is-empty) { error make {msg: "export-samples: at least one selector is required"} }
  let conf = (vm-conf $connection $url $token $set)
  let range = (promql resolve-range $last $start $end (date now))
  # --raw fetch: /export is JSON LINES, not a single JSON document, so parse each
  # non-empty line as its own JSON object.
  let text = (client export get --match $match --start (promql ts $range.start) --end (promql ts $range.end)
    --max-rows-per-line $max_rows_per_line
    --base-url (vm-base $conf) --token (vm-token $conf) --insecure=(vm-insecure $conf) --raw)
  let lines = ($text | lines | where {|l| $l | str trim | is-not-empty } | each {|l| $l | from json })
  if $raw { $lines } else { promql export-lines $lines }
}

# Make a victoriametrics connection the current one for this driver.
#
# Records the choice in `$env.MOLE_CURRENT.victoriametrics`, so later verbs can
# omit `--connection`. Validates that `name` exists and is a victoriametrics
# connection. Also warms the completion catalog (metric & label names) for the
# connection, best-effort — so tab-completion is ready right away.
@category mole-victoriametrics
@example "make the prod connection current" { mole-victoriametrics set-connection prod }
export def --env "set-connection" [
  name: string@complete-connection               # a victoriametrics connection name (from the connections file)
]: nothing -> nothing {
  let conf = (conn resolve $name --driver victoriametrics)
  $env.MOLE_CURRENT = (($env.MOLE_CURRENT? | default {}) | upsert victoriametrics $name)
  {name: $name} | cache write (vm-current-file)   # so completion finds it without $env
  try { vm-catalog-load $conf --refresh | ignore } catch { }
}
