use std/assert
use std/testing *
use ../promql.nu

# ---- value & time coercion ----------------------------------------------------

@test
def "num coerces sample-value strings" [] {
    assert equal (promql num "3.14") 3.14
    assert equal (promql num "0") 0.0
    assert equal (promql num "NaN") null          # Nushell has no NaN literal
    assert equal (promql num "+Inf" | describe) "float"
    assert equal (promql num null) null
}

@test
def "num passes non-strings through by default but applies an injected coercion" [] {
    assert equal (promql num 5) 5                  # default: identity, so an int stays an int
    assert equal (promql num 5 --coerce {|x| $x | into float }) 5.0   # injected superset form
    # the closure only fires on non-strings; a string still takes the common path
    assert equal (promql num "7" --coerce {|x| 999 }) 7.0
}

@test
def "time converts epoch seconds to datetime" [] {
    assert equal (promql time 0) 1970-01-01T00:00:00Z
    assert equal (promql time 1700000000) 2023-11-14T22:13:20Z
}

@test
def "ts converts datetime to a unix-seconds string, null-safe" [] {
    assert equal (promql ts 1970-01-01T00:00:01Z) "1"
    assert equal (promql ts null) null
}

@test
def "step renders integer seconds" [] {
    assert equal (promql step 15sec) "15s"
    assert equal (promql step 1min) "60s"
    assert equal (promql step 90sec) "90s"
}

# ---- label reshaping ----------------------------------------------------------

@test
def "relabel surfaces __name__ as metric" [] {
    assert equal (promql relabel {__name__: up, job: api}) {metric: up, job: api}
    assert equal (promql relabel {job: api}) {job: api}    # unchanged when __name__ absent
}

# ---- result normalization -----------------------------------------------------

@test
def "vector yields one typed row per series" [] {
    let out = promql vector [{metric: {__name__: up, job: api}, value: [0, "1"]}]
    assert equal $out [{metric: up, job: api, value: 1.0, timestamp: 1970-01-01T00:00:00Z}]
}

@test
def "matrix yields tidy rows, one per point" [] {
    let out = promql matrix [{metric: {__name__: up}, values: [[0, "1"], [60, "0"]]}]
    assert equal ($out | length) 2
    assert equal ($out | first) {metric: up, timestamp: 1970-01-01T00:00:00Z, value: 1.0}
    assert equal ($out | last | get value) 0.0
}

@test
def "scalar becomes one row and empty stays empty" [] {
    assert equal (promql scalar [0, "42"]) [{timestamp: 1970-01-01T00:00:00Z, value: 42.0}]
    assert equal (promql scalar []) []
}

@test
def "normalize dispatches on resultType, passing unknowns through" [] {
    assert equal (promql normalize {resultType: vector, result: [{metric: {__name__: up}, value: [0, "1"]}]}) [{metric: up, value: 1.0, timestamp: 1970-01-01T00:00:00Z}]
    assert equal (promql normalize {resultType: scalar, result: [0, "1"]}) [{timestamp: 1970-01-01T00:00:00Z, value: 1.0}]
    assert equal ((promql normalize {resultType: matrix, result: [{metric: {}, values: [[0, "1"]]}]}) | length) 1
    assert equal (promql normalize {resultType: foo, result: []}) {resultType: foo, result: []}
}

# ---- metadata -----------------------------------------------------------------

@test
def "metadata flattens rows and normalizes empty strings to null" [] {
    let out = promql metadata {up: [{type: gauge, help: "1 if up", unit: ""}]}
    assert equal $out [{metric: up, type: gauge, help: "1 if up", unit: null}]
    # a real unit passes through; an empty help is normalized to null too
    let out2 = promql metadata {req_seconds: [{type: counter, help: "", unit: "seconds"}]}
    assert equal $out2 [{metric: req_seconds, type: counter, help: null, unit: seconds}]
}

# ---- query composition (the select builder) -----------------------------------

@test
def "matcher-parts splits on the first equals only" [] {
    assert equal (promql matcher-parts "status=5..") {label: status, value: "5.."}
    assert equal (promql matcher-parts "path=/a=b") {label: path, value: "/a=b"}   # value keeps later =
    assert equal (promql matcher-parts "nolabel") null
}

@test
def "matchers renders the four kinds, quoted and comma-joined" [] {
    assert equal (promql matchers ["job=api" "method=GET"] [] ["status=5.."] []) '{job="api", method="GET", status=~"5.."}'
    assert equal (promql matchers [] [] [] []) ""
    assert equal (promql matchers [] ["job=api"] [] ["env=dev"]) '{job!="api", env!~"dev"}'
}

@test
def "matchers escapes quotes and backslashes in values" [] {
    assert equal (promql matchers ['path=a"b'] [] [] []) '{path="a\"b"}'
}

@test
def "build assembles selector, range, func and aggregation in order" [] {
    assert equal (promql build "up") "up"
    assert equal (promql build "up" --matchers '{job="api"}') 'up{job="api"}'
    assert equal (promql build "m" --range "5m" --func "rate") "rate(m[5m])"
    assert equal (promql build "http_requests_total" --matchers '{job="api"}' --range "5m" --func "rate" --agg "sum" --by [job]) 'sum by (job) (rate(http_requests_total{job="api"}[5m]))'
    assert equal (promql build "x" --agg "avg" --without [instance]) "avg without (instance) (x)"
}

@test
def "build requires a metric" [] {
    assert error { promql build "" }
}

# ---- static vocab -------------------------------------------------------------

@test
def "vocab lists are non-empty and a superset extends via ++" [] {
    assert ((promql funcs | length) > 0)
    assert ("rate" in (promql funcs))
    assert ("sum" in (promql aggs))
    assert (not ("rollup" in (promql funcs)))                   # rollup is MetricsQL-only, not a base func
    assert ("rollup" in ((promql funcs) ++ [rollup]))           # a superset injects its extras
    assert ((promql windows | length) > 0)
}

# ---- pure completion / context parsing ----------------------------------------

@test
def "parse-flag reads the last occurrence of a flag" [] {
    assert equal (promql parse-flag "query up -c prod" ["--connection" "-c"]) "prod"
    assert equal (promql parse-flag "query up --connection=stage -c prod" ["--connection" "-c"]) "prod"
    assert equal (promql parse-flag "query up" ["--connection" "-c"]) null
}

@test
def "metric-arg finds the metric positional, skipping value flags" [] {
    assert equal (promql metric-arg "select http_requests_total --eq [job=api]") "http_requests_total"
    assert equal (promql metric-arg "select up --dry-run") "up"                  # switch does not consume the metric
    assert equal (promql metric-arg "select -c prod up") "up"                    # value flag + arg are skipped
    assert equal (promql metric-arg "select --eq ") null                         # nothing typed yet
}

# ---- time range (clock injected) ----------------------------------------------

@test
def "resolve-range resolves --last against the injected now" [] {
    let now = 2023-11-14T22:13:20Z
    assert equal (promql resolve-range 1min null null $now) {start: 2023-11-14T22:12:20Z, end: $now}
    assert equal (promql resolve-range null null null $now) {start: null, end: null}
    # explicit start/end win over --last
    assert equal (promql resolve-range 1min 2020-01-01T00:00:00Z 2020-01-02T00:00:00Z $now) {start: 2020-01-01T00:00:00Z, end: 2020-01-02T00:00:00Z}
}
