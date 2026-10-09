# mole-prometheus — Prometheus driver plugin (READ-ONLY HTTP API).
#
# A PLUGIN (data source): supports the `prometheus` driver, registers itself as a
# driver, and exposes read-only verbs — `raw-query` / `raw-query-range` (raw PromQL)
# and the composing `select` / `series` / `labels` / `label-values` (a metric plus
# matcher TOKENS, `up job=api status=~5..`, fully tab-completed) / `metrics`. It
# talks to Prometheus over its HTTP API using Nushell's built-in `http` (no external
# CLI), with no external dependencies. mole-victoriametrics is its near-twin (same
# verbs, same token model, same completers); the shared pure pieces — the PromQL
# builder, the scoping selector, the result typing — live in mole-promql.
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

export-env {
  conn register "prometheus"
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
  cache fetch (cache path "prometheus" ($conf | get -o name | default "_")) 1day --refresh=$refresh {||
    let base = (pq-base $conf)
    let tok = (pq-token $conf)
    let ins = (pq-insecure $conf)
    let metrics = (client label-values get "__name__" --base-url $base --token $tok --insecure=$ins --max-time 10sec | get -o data | default [])
    let labels = (client labels get --base-url $base --token $tok --insecure=$ins --max-time 10sec | get -o data | default [])
    {meta: {connection: ($conf | get -o name), driver: "prometheus"}, metrics: $metrics, labels: $labels}
  }
}

# Warm the catalog after a successful query, but only when it is cold (missing).
# Best-effort: the connection is known reachable here, so this is cheap and never
# breaks the calling command. `set-connection` is the explicit refresh point.
def pq-warm [conf: record]: nothing -> nothing {
  let file = (cache path "prometheus" ($conf | get -o name | default "_"))
  if (cache read $file | is-not-empty) { return }
  try { pq-catalog-load $conf | ignore } catch { }
}

# The cached catalog for whatever connection the line targets (cache-only, instant).
# `complete catalog-ctx` resolves the connection the shared way — the typed `-c`, else
# the session-current, else the `__current__` mirror `conn set-current` writes — and
# reads the name-keyed cache file; nothing resolves → {}.
def pq-catalog-ctx [context: string]: nothing -> record {
  complete catalog-ctx $context "prometheus"
}

# ---- contextual completion ----------------------------------------------------
# Every completer resolves the connection / catalog / metric / siblings / window the
# line targets, then scopes its suggestions. The shared `complete` toolkit does the
# parsing and NEVER throws, so a Tab never errors; these add the metrics-specific
# projection on top. The scoping selector itself is `promql scope` and the
# positional split is `promql split-tokens` — both shared with mole-victoriametrics,
# whose `vm-*` completers are the twins of these.

# The verb on a completion line (the first known-verb token), so metric recovery can
# account for `label-values`' leading <label> positional.
def pq-ctx-verb [context: string]: nothing -> string {
  let known = [select series labels label-values metrics]
  $context | split row --regex '\s+' | where {|t| $t in $known } | get -o 0 | default "select"
}

# The metric already typed on the line: the `--metric` flag if present (how
# `label-values` names it, so the flag can precede the <label> and scope its
# completion), else the first operator-free positional (how the metric-first verbs
# name it; `promql split-tokens` does the split). `label-values` has NO positional
# metric — its first positional is the <label> — so it never mistakes that for a
# metric. Null when none is present.
def pq-ctx-metric [context: string]: nothing -> any {
  let flagged = (complete flag $context ["--metric" "-M"])
  if ($flagged | is-not-empty) { return $flagged }
  if (pq-ctx-verb $context) == "label-values" { return null }
  promql split-tokens (complete positionals $context) | get metric
}

# The sibling matcher tokens already typed (the operator-bearing positionals); the
# metric and any <label> positional are operator-free, so they drop out naturally.
def pq-ctx-siblings [context: string]: nothing -> list<string> {
  promql split-tokens (complete positionals $context) | get matchers
}

# The selector the line implies (metric + siblings), for scoping live lookups.
def pq-ctx-selector [context: string]: nothing -> string {
  try { promql scope (pq-ctx-metric $context) (pq-ctx-siblings $context) } catch { "" }
}

# The {start, end} window implied by the --last/--start/--end flags on the line
# (absent/unparseable → unbounded), so contextual lookups honor the typed window.
def pq-range-ctx [context: string]: nothing -> record {
  let f = (complete range-flags $context)
  promql resolve-range $f.last $f.start $f.end (date now)
}

# Metric NAMES from the cached catalog. `pq-expr` starts a raw PromQL expression; the
# cheapest useful suggestion is a metric name. (Label-name completion is `pq-mlabel`,
# which scopes to the metric on the line.)
def "pq-metric" [context: string]: nothing -> list<string> { pq-catalog-ctx $context | get -o metrics | default [] }
def "pq-expr" [context: string]: nothing -> list<string> { pq-metric $context }

# Static PromQL function / aggregation / range-window completers (no server call);
# the base vocab lives in the library. Prometheus is plain PromQL — no extras.
def "pq-func" [context: string]: nothing -> list<string> { promql funcs }
def "pq-agg" [context: string]: nothing -> list<string> { promql aggs }
def "pq-window" [context: string]: nothing -> list<string> { promql windows }

# Metric-scoped label NAMES for completion. `__name__` is dropped — the metric
# positional is how you pin it.
#
# With NO metric on the line, there is nothing to scope by, so the global cached
# label names are the reasonable start. With a metric present, this is a LIVE
# `/labels?match[]=<selector>` scoped to the metric + sibling matchers + the typed
# window (short timeout), and the result is authoritative: a successful-but-EMPTY
# result means the metric has no such labels (or doesn't exist), and an ERROR/timeout
# means we can't tell — either way it returns EMPTY rather than the global catalog,
# which would offer labels the metric does not have. (The global set is misleading
# here precisely because it is NOT scoped; a Tab that shows nothing is honest.)
def "pq-mlabel" [context: string]: nothing -> list<string> {
  let conf = (complete conn-ctx $context "prometheus")
  let sel = (pq-ctx-selector $context)
  if ($conf | is-empty) or ($sel | is-empty) {
    return (pq-catalog-ctx $context | get -o labels | default [] | where {|l| $l != "__name__" })
  }
  let r = (pq-range-ctx $context)
  try {
    (client labels get --qp-match [$sel] --start (promql ts $r.start) --end (promql ts $r.end)
      --base-url (pq-base $conf) --token (pq-token $conf) --insecure=(pq-insecure $conf) --max-time 3sec
      | get -o data | default [] | where {|l| $l != "__name__" })
  } catch { [] }
}

# Rest-positional completer for matcher tokens. Two stages on the token under the
# cursor, both contextual to the metric + sibling matchers + window on the line:
#   - no operator → field stage: `label=` for each metric-scoped label (pq-mlabel).
#   - `label<op>…` → value stage: a LIVE `label-values` for that label, scoped by the
#      sibling selector + window, returning `label<op>value` (the operator the user
#      chose is preserved). The stage branches on `matcher-token` (never `str contains
#      "="`, which `!=`/`=~`/`!~` all satisfy). Best-effort — errors → no candidates.
def "pq-matcher" [context: string]: nothing -> list<string> {
  let tok = (complete token $context)
  let parsed = (promql matcher-token $tok)
  if ($parsed == null) {
    (pq-mlabel $context) | each {|l| $l + "=" }
  } else {
    let conf = (complete conn-ctx $context "prometheus")
    if ($conf | is-empty) { return [] }
    let sel = (pq-ctx-selector $context)
    let match = (if ($sel | is-empty) { [] } else { [$sel] })
    let r = (pq-range-ctx $context)
    try {
      (client label-values get $parsed.label --qp-match $match
        --start (promql ts $r.start) --end (promql ts $r.end)
        --base-url (pq-base $conf) --token (pq-token $conf) --insecure=(pq-insecure $conf) --max-time 3sec
      | get -o data | default []
      | each {|v| $parsed.label + $parsed.op + $v })
    } catch { [] }
  }
}

# Completer for the comma-separated `--by`/`--without`: metric-scoped label names,
# re-prepending the already-typed comma items so accepting a candidate EXTENDS the
# list (`job,me⇥` → `job,method`).
def "pq-by" [context: string]: nothing -> list<string> {
  complete csv-extend $context (pq-mlabel $context)
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
@example "instant value of a metric" { mole-prometheus raw-query "up" }
@example "an aggregation, at a specific instant" { mole-prometheus raw-query "sum by (job) (up)" --time 2026-07-26T00:00:00Z }
@example "a saved query against a named connection" { mole-prometheus raw-query --file dashboards/errors.promql -c prod }
@example "query text piped via stdin" { mole query show dashboards/errors.promql | mole-prometheus raw-query -c prod }
export def "raw-query" [
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
# Same expression sources as `raw-query`. The window is `--last` (now minus a
# duration), or explicit `--start`/`--end`; `--step` is the resolution (default
# 15s). A `matrix` result comes back tidy: one row per (series, point), every
# label a column (`__name__` as `metric`), plus `timestamp` (datetime) and `value`
# (float). `--raw`/`--full` and the connection flags behave as in `raw-query`.
@category mole-prometheus
@example "last hour of a rate, at 1-minute resolution" { mole-prometheus raw-query-range "rate(http_requests_total[5m])" --last 1hr --step 1min }
@example "an explicit window" { mole-prometheus raw-query-range "up" --start 2026-07-26T00:00:00Z --end 2026-07-26T06:00:00Z --step 5min }
export def "raw-query-range" [
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
  if ($range.start | is-empty) { error make {msg: "raw-query-range needs a window: pass --last, or --start/--end"} }
  let resp = (client query-range list --query $q
    --start (promql ts $range.start) --end (promql ts $range.end) --step (promql step $step)
    --limit $limit --timeout $timeout
    --base-url (pq-base $conf) --token (pq-token $conf) --insecure=(pq-insecure $conf))
  pq-warm $conf
  if $full { return $resp }
  let data = ($resp | get -o data)
  if $raw { $data } else { promql normalize $data }
}

# Compose and run a PromQL query from completion-aware tokens — the ergonomic
# alternative to writing raw PromQL in `raw-query`.
#
# Assembles `[agg [by/without (labels)]] ( [func] ( metric{matchers}[range] ) )`
# from the metric, the matcher tokens and the flags, then runs it: INSTANT by
# default, or as a RANGE query when any of `--last`/`--start`/`--end` is given.
# `--dry-run` returns a `{connection, query}` record — the resolved connection
# (secrets dropped) and the assembled PromQL — without running.
#
# Completion is the point. `<metric>` completes from the catalog; each `...matchers`
# token completes the label name first, then — after an operator — that label's LIVE
# values, SCOPED to the metric and the sibling matchers already typed (and the time
# window). A matcher token is `label=value` (→ `label="value"`), `label!=value`,
# `label=~value` (regex) or `label!~value`; the value is quoted for you, so type
# `code=~5..`, NOT `code=~"5.."`, and single-quote a value with spaces
# (`'msg=hello world'`). `--func`/`--agg` complete from the PromQL
# function/aggregation sets; `--by`/`--without` are comma-separated lists of the
# metric's labels. Results are typed exactly as `raw-query`/`raw-query-range`.
@category mole-prometheus
@example "filter a metric by labels (instant)" {
  mole-prometheus select http_requests_total job=api method=GET --dry-run | get query
} --result 'http_requests_total{job="api", method="GET"}'
@example "a rate aggregated by job (range window applied at run time)" {
  mole-prometheus select http_requests_total job=api status=~5.. --range 5m --func rate --agg sum --by job --last 1hr --step 1min --dry-run | get query
} --result 'sum by (job) (rate(http_requests_total{job="api", status=~"5.."}[5m]))'
@example "run it for real against a connection" {
  mole-prometheus select up job=prometheus -c prometheus-local-dev
}
export def "select" [
  metric: string@"pq-metric"                       # metric name (completes from the catalog)
  ...matchers: string@"pq-matcher"                 # label matchers: label=value | label!=value | label=~value | label!~value
  --range(-r): string@"pq-window"                  # range-vector window, e.g. 5m → [5m] (for rate/increase/…)
  --func: string@"pq-func"                         # wrap the selector in this function (rate, increase, …)
  --agg: string@"pq-agg"                           # aggregate with this operator (sum, avg, topk, …)
  --by: string@"pq-by"                             # aggregation grouping: by (labels), comma-separated — needs --agg
  --without: string@"pq-by"                        # aggregation grouping: without (labels), comma-separated — needs --agg
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
  if ((promql matcher-token $metric) != null) {
    error make {msg: "select: the first argument must be a metric name, not a matcher"}
  }
  let by = (complete csv $by)
  let without = (complete csv $without)
  if (($by | is-not-empty) or ($without | is-not-empty)) and ($agg | is-empty) {
    error make {msg: "select: --by/--without require --agg"}
  }
  if ($by | is-not-empty) and ($without | is-not-empty) {
    error make {msg: "select: --by and --without are mutually exclusive"}
  }
  let expr = (promql build $metric
    --matchers (promql matchers-tokens $matchers)
    --range ($range | default "")
    --func ($func | default "")
    --agg ($agg | default "")
    --by $by
    --without $without)
  if $dry_run { return {connection: (pq-conf $connection $url $token $set | conn redact), query: $expr} }
  if (($last | is-not-empty) or ($start | is-not-empty) or ($end | is-not-empty)) {
    raw-query-range $expr --last $last --start $start --end $end --step $step --limit $limit --connection $connection --url $url --token $token --set $set --raw=$raw --full=$full
  } else {
    raw-query $expr --time $time --limit $limit --connection $connection --url $url --token $token --set $set --raw=$raw --full=$full
  }
}

# List the series matching a selector.
#
# Builds ONE selector from `<metric>` + matcher tokens (`series up job=api
# status=~5..`), exactly like `select`, and returns one row per matching series — a
# table of its label sets. A metric that is itself a matcher (`series job=api`)
# becomes a bare `{job="api"}` selector. The window (`--last` / `--start` / `--end`)
# is optional and scopes the lookup; omit it to search all time.
@category mole-prometheus
@example "series for a metric" { mole-prometheus series up }
@example "series for a filtered selector in the last day" { mole-prometheus series up job=api --last 1day }
@example "inspect the composed selector without running" { mole-prometheus series up job=api --dry-run | get query } --result 'up{job="api"}'
export def "series" [
  metric?: string@"pq-metric"                      # metric name (completes from the catalog)
  ...matchers: string@"pq-matcher"                 # label matchers (AND-joined into the selector)
  --last(-L): duration                             # scope to a window ending now
  --start(-a): datetime                            # window start
  --end(-b): datetime                              # window end
  --limit(-l): int                                 # max number of series to return
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string
  --token: string
  --set: record = {}
  --dry-run(-n)                                    # return {connection, query} instead of running
] {
  let sel = (promql scope $metric $matchers)
  if ($sel | is-empty) { error make {msg: "series: a metric or at least one matcher is required"} }
  let conf = (pq-conf $connection $url $token $set)
  if $dry_run { return {connection: ($conf | conn redact), query: $sel} }
  let range = (promql resolve-range $last $start $end (date now))
  (client series get --qp-match [$sel] --start (promql ts $range.start) --end (promql ts $range.end) --limit $limit
    --base-url (pq-base $conf) --token (pq-token $conf) --insecure=(pq-insecure $conf))
  | get -o data | default []
  | each {|r| promql relabel $r }   # surface __name__ as `metric`, as raw-query/raw-query-range do
}

# List label names present in the data (optionally scoped by a selector/window).
#
# Scope with `[metric]` + matcher tokens (`labels up job=api`), exactly like
# `select`; with no arguments it returns every label name. The window scopes the
# lookup.
@category mole-prometheus
@example "all label names" { mole-prometheus labels }
@example "label names used by a selector" { mole-prometheus labels up --last 1hr }
@example "inspect the composed selector without running" { mole-prometheus labels up job=api --dry-run | get query } --result 'up{job="api"}'
export def "labels" [
  metric?: string@"pq-metric"                      # metric to scope by (completes from the catalog)
  ...matchers: string@"pq-matcher"                 # label matchers to further scope the label names
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --limit(-l): int
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
  --dry-run(-n)                                    # return {connection, query} instead of running
] {
  let conf = (pq-conf $connection $url $token $set)
  let sel = (promql scope $metric $matchers)
  if $dry_run { return {connection: ($conf | conn redact), query: $sel} }
  let range = (promql resolve-range $last $start $end (date now))
  let match = (if ($sel | is-empty) { null } else { [$sel] })
  (client labels get --qp-match $match --start (promql ts $range.start) --end (promql ts $range.end) --limit $limit
    --base-url (pq-base $conf) --token (pq-token $conf) --insecure=(pq-insecure $conf))
  | get -o data | default []
}

# List the distinct values of a label (optionally scoped by a metric/matchers/window).
#
# `--metric M` scopes the lookup — and, typed FIRST, makes the <label> itself
# complete to only M's labels, so you can tab through a metric's labels while
# exploring (`label-values --metric up ⇥`). Add matcher tokens to narrow further
# (`label-values --metric up instance job=api`), like `select`. `--limit` caps the
# values. With no `--metric`, <label> completes from the global catalog and the
# values span every series.
@category mole-prometheus
@example "every job value" { mole-prometheus label-values job }
@example "explore a metric's labels, then a label's values" { mole-prometheus label-values --metric up instance }
@example "values within a filtered selector" { mole-prometheus label-values --metric up instance job=api }
@example "inspect the composed selector without running" { mole-prometheus label-values instance --metric up job=api --dry-run | get query } --result 'up{job="api"}'
export def "label-values" [
  label: string@"pq-mlabel"                        # the label name to enumerate (completes to --metric's labels when given)
  --metric(-M): string@"pq-metric"                 # metric to scope by (completes from the catalog)
  ...matchers: string@"pq-matcher"                 # label matchers to further scope the values
  --last(-L): duration
  --start(-a): datetime
  --end(-b): datetime
  --limit(-l): int
  --connection(-c): string@complete-connection
  --url: string
  --token: string
  --set: record = {}
  --dry-run(-n)                                    # return {connection, query} instead of running
] {
  let conf = (pq-conf $connection $url $token $set)
  let sel = (promql scope $metric $matchers)
  if $dry_run { return {connection: ($conf | conn redact), query: $sel} }
  let range = (promql resolve-range $last $start $end (date now))
  let match = (if ($sel | is-empty) { null } else { [$sel] })
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
  let conf = (conn set-current prometheus $name)
  try { pq-catalog-load $conf --refresh | ignore } catch { }
}
