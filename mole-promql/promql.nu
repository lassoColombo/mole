# mole-promql — generic Prometheus-HTTP-API LIBRARY (tool-agnostic). Not a
# plugin/driver: it exposes shared helpers that metrics plugins (mole-prometheus,
# mole-victoriametrics, …) import via `use mole-promql/promql.nu` (→ `promql
# normalize`, `promql build`, …). No export-env, no driver registration, no
# manifest — a pure library discovered via `NU_LIB_DIRS`.
#
# LAYERING: this file is a PURE library — it `use`s NOTHING (not mole core, not
# any plugin) and every command is data-in / data-out with NO I/O and NO clock.
# Anything that touches a connection, an HTTP client, the cache, the clock, or the
# environment lives in the dialect PLUGIN, which orchestrates by composing these
# helpers. The verbs and their completers stay in the plugin too: a completer must
# resolve a driver-specific cache/connection and runs in an env the plugin owns,
# and each plugin calls its OWN generated HTTP client — neither can live here.
#
# WHAT IS TRULY COMMON (and so lives here): the Prometheus HTTP-API WIRE FORMAT.
# Every tool that speaks it encodes sample VALUES as strings ("3.14", "NaN",
# "+Inf"), TIMESTAMPS as Unix seconds (a float), and returns the same polymorphic
# {resultType, result} envelope and {metric: [{type, help, unit}, …]} metadata.
# PromQL selector/matcher syntax is the shared query-composition baseline. These
# helpers own exactly that and nothing more.
#
# DIALECT PECULIARITIES ARE INJECTED, never hardcoded here. A tool's superset adds
# to the common core through an ARGUMENT — a primitive or a closure — so a new tool
# can reuse this library without forking it:
#   - `num --coerce {|x| …}` : how a NON-string sample value is coerced. The wire
#     form (strings) is universal and baked in; a native-number representation
#     (e.g. VictoriaMetrics /export returns JSON numbers) is the injected part.
#     Default: pass the value through untouched (the pure query-API behaviour).
#   - `funcs`/`aggs` : the PromQL BASE vocab; a superset plugin extends it with
#     `(promql funcs) ++ [its-extras]` (e.g. MetricsQL's rollup functions).
#   - `resolve-range … now` : the clock is passed IN, keeping the library
#     clock-free while still owning the --last/--start/--end resolution logic.

# ---- value & time coercion ----------------------------------------------------
# Prometheus encodes every query-API sample value as a string ("3.14", "NaN",
# "+Inf") and every timestamp as Unix seconds (a float); these helpers own that.

# A sample value → a real number.
#
# The COMMON wire form is a STRING: `NaN` becomes null (Nushell has no NaN
# literal); `+Inf`/`-Inf` parse to `inf`/`-inf`; any other numeric string → float;
# a string `into float` can't parse is kept as-is; `null` stays `null`.
#
# A NON-string value is dialect-specific — its coercion is INJECTED via `--coerce`
# (default: pass through unchanged). The query API only ever yields strings, so the
# closure never fires there; a tool whose endpoint returns native numbers (e.g.
# VictoriaMetrics /export) passes `--coerce {|x| $x | into float}` at that site.
@category mole-promql
@example "a numeric string becomes a float" { promql num "3.14" } --result 3.14
@example "NaN becomes null" { promql num "NaN" } --result null
@example "a non-string passes through by default" { promql num 5 } --result 5
@example "an injected coercion is applied to a non-string" {
  promql num 5 --coerce {|x| $x | into float }
} --result 5.0
export def "num" [
  v: any
  --coerce: closure   # coercion for a NON-string value (superset form); unset = pass through unchanged
]: nothing -> any {
  if $v == null { return null }
  if ($v | describe) == "string" {
    if $v == "NaN" { return null }
    return (try { $v | into float } catch { $v })
  }
  if ($coerce == null) { $v } else { do $coerce $v }
}

# A Prometheus Unix timestamp (float seconds) → datetime.
@category mole-promql
@example "epoch seconds to datetime" { promql time 0 } --result 1970-01-01T00:00:00Z
export def "time" [ts: any]: nothing -> datetime { 1970-01-01T00:00:00Z + (($ts | into float) * 1sec) }

# A datetime → the Unix-timestamp string Prometheus wants for time params. Null
# passes through as null (so an unset flag stays omitted on the wire).
@category mole-promql
@example "datetime to unix-seconds string" { promql ts 1970-01-01T00:00:01Z } --result "1"
@example "null stays null" { promql ts null } --result null
export def "ts" [dt: any]: nothing -> any {
  if ($dt | is-empty) { null } else { (($dt - 1970-01-01T00:00:00Z) / 1sec) | into string }
}

# A duration → the Prometheus step string (integer seconds, e.g. `15s`).
@category mole-promql
@example "duration to step string" { promql step 1min } --result "60s"
export def "step" [d: duration]: nothing -> string { $"(($d / 1sec) | into int)s" }

# ---- result normalization -----------------------------------------------------

# A Prometheus label set → a record, surfacing `__name__` as `metric` (the first
# column) and keeping every other label as its own column.
@category mole-promql
@example "__name__ becomes metric" { promql relabel {__name__: up, job: api} } --result {metric: up, job: api}
@example "a label set with no __name__ is unchanged" { promql relabel {job: api} } --result {job: api}
export def "relabel" [m: record]: nothing -> record {
  let name = ($m | get -o __name__)
  let rest = if ("__name__" in ($m | columns)) { $m | reject __name__ } else { $m }
  if ($name | is-empty) { $rest } else { {metric: $name} | merge $rest }
}

# instant `vector` result → one row per series: {..labels, value, timestamp}.
@category mole-promql
@example "a one-series vector" {
  promql vector [{metric: {__name__: up, job: api}, value: [1700000000, "1"]}]
} --result [{metric: up, job: api, value: 1.0, timestamp: 2023-11-14T22:13:20Z}]
export def "vector" [result: list]: nothing -> table {
  $result | each {|s| (relabel $s.metric) | merge {value: (num $s.value.1), timestamp: (time $s.value.0)} }
}

# range `matrix` result → tidy rows: one per (series, point) {..labels, timestamp, value}.
@category mole-promql
@example "a two-point matrix series" {
  promql matrix [{metric: {__name__: up}, values: [[0, "1"], [60, "0"]]}]
} --result [{metric: up, timestamp: 1970-01-01T00:00:00Z, value: 1.0}, {metric: up, timestamp: 1970-01-01T00:01:00Z, value: 0.0}]
export def "matrix" [result: list]: nothing -> table {
  $result | each {|s|
    let labels = (relabel $s.metric)
    $s.values | each {|p| $labels | merge {timestamp: (time $p.0), value: (num $p.1)} }
  } | flatten
}

# `scalar` / `string` result ([ts, "val"]) → a single {timestamp, value} row.
@category mole-promql
@example "a scalar result" { promql scalar [0, "42"] } --result [{timestamp: 1970-01-01T00:00:00Z, value: 42.0}]
export def "scalar" [result: list]: nothing -> table {
  if ($result | is-empty) { [] } else { [{timestamp: (time $result.0), value: (num $result.1)}] }
}

# Turn a query `data` payload into typed rows, dispatching on its resultType.
# An unrecognized shape is returned untouched.
@category mole-promql
@example "dispatch on a vector payload" {
  promql normalize {resultType: vector, result: [{metric: {__name__: up}, value: [0, "1"]}]}
} --result [{metric: up, value: 1.0, timestamp: 1970-01-01T00:00:00Z}]
export def "normalize" [data: any]: nothing -> any {
  if (($data | describe) !~ '^record') { return $data }
  match ($data | get -o resultType) {
    "vector" => (vector ($data | get -o result | default []))
    "matrix" => (matrix ($data | get -o result | default []))
    "scalar" => (scalar ($data | get -o result | default []))
    "string" => (scalar ($data | get -o result | default []))
    _ => $data
  }
}

# An empty string → null ("no data"); any other value passes through unchanged.
def nullify-blank [v: any]: nothing -> any {
  if (($v | describe) == "string") and ($v | is-empty) { null } else { $v }
}

# metadata `data` ({metric: [{type, help, unit}, …], …}) → a flat table of
# {metric, type, help, unit} rows. Empty strings are normalized to null: the
# Prometheus HTTP API itself reports `unit: ""` for every metric that lacks
# OpenMetrics `# UNIT` metadata (i.e. almost all of them) and `help: ""` for
# metrics with no HELP — so this is a property of the SHARED wire format, not a
# dialect quirk. A blank cell reads as an unambiguous "no data".
@category mole-promql
@example "flatten a metadata payload; an empty unit becomes null" {
  promql metadata {up: [{type: gauge, help: "1 if up", unit: ""}]}
} --result [{metric: up, type: gauge, help: "1 if up", unit: null}]
export def "metadata" [data: any]: nothing -> any {
  if (($data | describe) !~ '^record') { return $data }
  $data | items {|name, entries|
    $entries | each {|e|
      {
        metric: $name
        type: (nullify-blank ($e | get -o type))
        help: (nullify-blank ($e | get -o help))
        unit: (nullify-blank ($e | get -o unit))
      }
    }
  } | flatten
}

# ---- query composition (pure; the `select` builder assembles with these) ------
# Parens are built with string concatenation, not `$"...(...)..."`, to avoid the
# sub-expression gotcha of literal parens inside an interpolation.

# Escape a matcher value for a PromQL double-quoted string literal.
def esc [v: string]: nothing -> string {
  $v | str replace --all '\' '\\' | str replace --all '"' '\"'
}

# Split a matcher token `label<op>value` into {label, op, value}; `op` is one of
# `=`, `!=`, `=~`, `!~`. Null when the token carries no operator. The operator is
# anchored right after the label identifier and the alternation is longest-first,
# so an operator that also appears INSIDE the value (e.g. `label=~a=b`) is never
# mis-detected. This is the token form the `select`/`series`/… completers and the
# `matchers-tokens` builder both parse.
@category mole-promql
@example "an equality token" { promql matcher-token "job=api" } --result {label: job, op: "=", value: api}
@example "a negative-regex token" { promql matcher-token "status!~5.." } --result {label: status, op: "!~", value: "5.."}
@example "a bare value keeps any later operators" { promql matcher-token "path=~/a=b" } --result {label: path, op: "=~", value: "/a=b"}
@example "no operator yields null" { promql matcher-token "nolabel" } --result null
export def "matcher-token" [token: string]: nothing -> any {
  let m = ($token | parse --regex '^(?P<label>[a-zA-Z_][a-zA-Z0-9_]*)(?P<op>=~|!~|!=|=)(?P<value>.*)$')
  if ($m | is-empty) { null } else { $m | first }
}

# Assemble the `{...}` matcher block from operator-carrying tokens (`job=api`,
# `status=~5..`, `env!=dev`). Each value is quoted and escaped (via `esc`). An empty
# list → "". Errors on a non-empty token that carries no operator — silently
# dropping it would run a wrongly-unfiltered query, the worst failure for a metrics
# tool. Each token names its own operator, so ONE list carries every matcher kind.
@category mole-promql
@example "mixed operators compose in order" {
  promql matchers-tokens ["job=api" "status=~5.." "env!=dev"]
} --result '{job="api", status=~"5..", env!="dev"}'
@example "no tokens → empty string" { promql matchers-tokens [] } --result ""
export def "matchers-tokens" [tokens: list<string>]: nothing -> string {
  let parts = ($tokens | where {|t| $t | is-not-empty } | each {|t|
    let p = (matcher-token $t)
    if ($p == null) { error make {msg: $"not a matcher: '($t)' — use label=value | label!=value | label=~value | label!~value; single-quote a value with spaces"} }
    $p.label + $p.op + '"' + (esc $p.value) + '"'
  })
  if ($parts | is-empty) { "" } else { "{" + ($parts | str join ", ") + "}" }
}

# Assemble a PromQL query from parts (pure):
#   [agg [by/without (labels)]] ( [func] ( metric{matchers}[range] ) )
# MetricsQL and every PromQL superset accept this syntax unchanged, so the builder
# needs no dialect injection.
@category mole-promql
@example "a rate wrapped in a sum-by" {
  promql build "http_requests_total" --matchers '{job="api"}' --range 5m --func rate --agg sum --by [job]
} --result 'sum by (job) (rate(http_requests_total{job="api"}[5m]))'
@example "just a metric with matchers" {
  promql build "up" --matchers '{job="api"}'
} --result 'up{job="api"}'
export def "build" [
  metric: string
  --matchers: string = ""       # the {...} block (from `matchers`)
  --range: string = ""          # range window, e.g. "5m" → [5m]
  --func: string = ""           # wrap the selector in this function
  --agg: string = ""            # aggregation operator
  --by: list<string> = []       # by (labels)
  --without: list<string> = []  # without (labels)
]: nothing -> string {
  if ($metric | is-empty) { error make {msg: "promql build: a metric is required"} }
  mut e = ($metric + $matchers)
  if ($range | is-not-empty) { $e = ($e + "[" + $range + "]") }
  if ($func | is-not-empty) { $e = ($func + "(" + $e + ")") }
  if ($agg | is-not-empty) {
    let grp = if ($by | is-not-empty) {
      " by (" + ($by | str join ", ") + ")"
    } else if ($without | is-not-empty) {
      " without (" + ($without | str join ", ") + ")"
    } else { "" }
    $e = ($agg + $grp + " (" + $e + ")")
  }
  $e
}

# ---- static vocab (the PromQL BASE; a superset plugin extends via `++`) --------

# PromQL functions worth completing. A superset (e.g. MetricsQL) does
# `(promql funcs) ++ [its-extras]`.
@category mole-promql
export def "funcs" []: nothing -> list<string> {
  [rate irate increase delta idelta deriv predict_linear histogram_quantile
   abs ceil floor round sgn sqrt exp ln log2 log10 clamp clamp_max clamp_min
   sum_over_time avg_over_time min_over_time max_over_time count_over_time
   last_over_time stddev_over_time stdvar_over_time quantile_over_time
   absent absent_over_time timestamp]
}

# PromQL aggregation operators.
@category mole-promql
export def "aggs" []: nothing -> list<string> {
  [sum avg min max count count_values group stddev stdvar topk bottomk quantile]
}

# Suggested range-vector windows.
@category mole-promql
export def "windows" []: nothing -> list<string> { [30s 1m 5m 10m 15m 30m 1h 3h 6h 12h 1d] }

# ---- selector scoping / context parsing (pure) --------------------------------
# Shared by the Prometheus-API drivers (mole-prometheus, mole-victoriametrics): the
# enumeration verbs build their scoping selector with `scope`, and the contextual
# completers classify the positionals already on the line with `split-tokens`.

# Build a scoping selector from an optional metric + matcher tokens. A "metric" that
# actually carries an operator (`labels job=api`) is folded into the matchers, so a
# verb's leading positional stays unambiguous. Returns `metric{block}`, a bare
# `{block}`, or "" (match everything). `select` builds its own expression via
# `build` (it also wraps func/agg/range). Errors, via `matchers-tokens`, on a bare
# non-matcher sibling.
@category mole-promql
@example "a metric plus matchers" { promql scope "up" ["job=api"] } --result 'up{job="api"}'
@example "a leading matcher folds into the block" { promql scope "job=api" ["env!=dev"] } --result '{job="api", env!="dev"}'
@example "nothing to scope by" { promql scope null [] } --result ""
export def "scope" [
  metric: any              # metric name, null / "" for none, or a matcher token (folded in)
  matchers: list<string>   # operator-carrying tokens (label=v | label!=v | label=~v | label!~v)
]: nothing -> string {
  let is_matcher = (($metric | is-not-empty) and ((matcher-token $metric) != null))
  let m = if $is_matcher { null } else { $metric }
  let toks = if $is_matcher { [$metric] ++ $matchers } else { $matchers }
  let block = (matchers-tokens $toks)
  if ($m | is-empty) { $block } else { $m + $block }
}

# Classify the positional tokens of a partial command line into the metric and the
# matcher siblings: `{metric: <first operator-free token | null>, matchers: <the
# operator-carrying tokens>}`. One pair of matching surrounding quotes is stripped
# first — the parser keeps them on a `'msg=hello world'` positional, and a quoted
# matcher would otherwise read as operator-free and masquerade as the metric. A
# driver feeds it `complete positionals <ctx>` and keeps its own policy on top (a
# `--metric` flag, a verb whose first positional is a <label>, …).
@category mole-promql
@example "metric first, matchers after" { promql split-tokens ["up" "job=api" "status=~5.."] } --result {metric: up, matchers: ["job=api" "status=~5.."]}
@example "no metric on the line" { promql split-tokens ["job=api"] } --result {metric: null, matchers: ["job=api"]}
@example "a quoted token is unwrapped before classifying" { promql split-tokens ["'msg=hello world'"] } --result {metric: null, matchers: ["msg=hello world"]}
export def "split-tokens" [tokens: list<string>]: nothing -> record {
  let toks = ($tokens | each {|t| unquote $t })
  {
    metric: ($toks | where {|t| (matcher-token $t) == null } | get -o 0)
    matchers: ($toks | where {|t| (matcher-token $t) != null })
  }
}

# Strip one matching pair of surrounding quotes from a token (the parser keeps them).
def unquote [s: string]: nothing -> string {
  let len = ($s | str length)
  if $len < 2 { return $s }
  let d = ($s | str substring 0..0)
  if ($d in ['"' "'"]) and ($s | str ends-with $d) { $s | str substring 1..($len - 2) } else { $s }
}

# ---- time range (clock injected, so the library stays pure) -------------------

# Resolve --last / --start / --end into a {start, end} of datetimes (either may be
# null = unbounded). Explicit --start/--end win; --last is "now minus dur",
# defaulting the missing end to now. The clock is passed IN as `now` (the plugin
# supplies `(date now)`), so this stays pure and deterministic to test.
@category mole-promql
@example "a --last window resolves against the injected now" {
  promql resolve-range 1min null null 2023-11-14T22:13:20Z
} --result {start: 2023-11-14T22:12:20Z, end: 2023-11-14T22:13:20Z}
@example "no window is unbounded" {
  promql resolve-range null null null 2023-11-14T22:13:20Z
} --result {start: null, end: null}
export def "resolve-range" [
  last: any        # a duration (window ending at `now`), or null
  start: any       # explicit start datetime (wins over --last), or null
  end: any         # explicit end datetime (wins over --last's now), or null
  now: datetime    # the current instant, injected by the caller
]: nothing -> record {
  let e = if ($end | is-not-empty) { $end } else if ($last | is-not-empty) { $now } else { null }
  let s = if ($start | is-not-empty) { $start } else if ($last | is-not-empty) { $now - $last } else { null }
  {start: $s, end: $e}
}
