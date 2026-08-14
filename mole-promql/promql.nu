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

# Split a `label=value` token on its FIRST `=` → {label, value}; null when there
# is no `=` (the value keeps any further `=`).
@category mole-promql
@example "split on the first =" { promql matcher-parts "status=5.." } --result {label: status, value: "5.."}
@example "no = yields null" { promql matcher-parts "status" } --result null
export def "matcher-parts" [token: string]: nothing -> any {
  if not ($token | str contains "=") { return null }
  let p = ($token | split row --number 2 "=")
  {label: ($p | first | str trim), value: ($p | get 1)}
}

# Render one matcher `label<op>"value"` from a `label=value` token (value quoted
# and escaped). Null for a token with no `=`.
def render-matcher [token: string, op: string]: nothing -> any {
  let p = (matcher-parts $token)
  if $p == null { null } else { $p.label + $op + '"' + (esc $p.value) + '"' }
}

# Assemble the `{...}` matcher block from the four matcher kinds; each list holds
# `label=value` tokens (value = the match RHS). Empty inputs → "".
@category mole-promql
@example "eq and regex matchers compose in order" {
  promql matchers ["job=api" "method=GET"] [] ["status=5.."] []
} --result '{job="api", method="GET", status=~"5.."}'
@example "no matchers → empty string" { promql matchers [] [] [] [] } --result ""
export def "matchers" [
  eq: list<string>    # label=value → label="value"
  ne: list<string>    # label=value → label!="value"
  re: list<string>    # label=value → label=~"value"
  nre: list<string>   # label=value → label!~"value"
]: nothing -> string {
  let parts = ([
    ...($eq  | each {|t| render-matcher $t "=" })
    ...($ne  | each {|t| render-matcher $t "!=" })
    ...($re  | each {|t| render-matcher $t "=~" })
    ...($nre | each {|t| render-matcher $t "!~" })
  ] | compact)
  if ($parts | is-empty) { "" } else { "{" + ($parts | str join ", ") + "}" }
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
# tool. This is the single-list superset of `matchers` (each token names its own
# operator instead of the caller splitting into four lists).
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

# ---- pure completion / context parsing ----------------------------------------

# Extract a flag's value from a raw completion-context command line.
#
# Tries each spelling in `names` (long and short), accepts `--flag value` or
# `--flag=value`, and when the flag appears more than once takes the last
# occurrence. Returns `null` when no spelling is present. A plugin completer uses
# this to recover the `--connection` a user has already typed.
@category mole-promql
@example "read a flag the user already typed" {
  promql parse-flag "query up -c prod" ["--connection" "-c"]
} --result prod
@example "null when the flag is absent" {
  promql parse-flag "query up" ["--connection" "-c"]
} --result null
export def "parse-flag" [
  ctx: string           # the completion context (the partial command line)
  names: list<string>   # flag spellings to try, e.g. ["--connection" "-c"]
]: nothing -> any {
  let m = ($ctx | parse --regex ('(?:' + ($names | str join "|") + ')[\s=]+(?P<v>[^\s]+)'))
  if ($m | is-empty) { null } else { $m | last | get v }
}

# The metric positional already typed on a `select` line — used to scope label and
# value completion to that metric. Walks the tokens after `select`, skipping a
# value-flag and its argument (switches don't consume the next token); returns the
# first bare token (or null). The switch set is the select-builder's own
# (`--raw`/`--full`/`--dry-run`), shared by every dialect's `select`.
@category mole-promql
@example "the metric typed before the flags" {
  promql metric-arg "select http_requests_total --eq [job=api]"
} --result http_requests_total
@example "no metric yet yields null" { promql metric-arg "select --eq " } --result null
export def "metric-arg" [context: string]: nothing -> any {
  let toks = ($context | str trim | split row --regex '\s+')
  let sel = ($toks | enumerate | where item == "select" | get -o 0.index)
  let after = if ($sel == null) { $toks } else { $toks | skip ($sel + 1) }
  let switches = ["--raw" "-R" "--full" "-F" "--dry-run" "-n"]
  mut skip = false
  mut found = ""
  for t in $after {
    if $skip { $skip = false; continue }
    if ($t | str starts-with "-") {
      if ($t not-in $switches) and (not ($t | str contains "=")) { $skip = true }
      continue
    }
    $found = $t
    break
  }
  if ($found | is-empty) { null } else { $found }
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
