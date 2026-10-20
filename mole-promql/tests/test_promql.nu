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
    assert equal (promql step 500ms) "500ms"     # never truncated to the rejected `0s`
    assert equal (promql step 1500ms) "1500ms"
}

@test
def "step rejects zero, negative and sub-millisecond durations" [] {
    assert error { promql step 0sec }
    assert error { promql step (0sec - 15sec) }
    assert error { promql step 5ns }
}

# ---- label reshaping ----------------------------------------------------------

@test
def "relabel surfaces __name__ as metric" [] {
    assert equal (promql relabel {__name__: up, job: api}) {metric: up, job: api}
    assert equal (promql relabel {job: api}) {job: api}    # unchanged when __name__ absent
}

# ---- result normalization -----------------------------------------------------

@test
def "vector yields one typed row per series, columns ordered like matrix" [] {
    let out = promql vector [{metric: {__name__: up, job: api}, value: [0, "1"]}]
    assert equal $out [{metric: up, job: api, timestamp: 1970-01-01T00:00:00Z, value: 1.0}]
    assert equal ($out | columns) [metric job timestamp value]
    assert equal (promql matrix [{metric: {__name__: up, job: api}, values: [[0, "1"]]}] | columns) [metric job timestamp value]
}

@test
def "vector and matrix carry a native-histogram sample as a record instead of failing" [] {
    let h = {count: "1", sum: "2.5", buckets: [[0, "0", "1", "1"]]}
    let v = promql vector [{metric: {__name__: up}, value: [0, "1"]} {metric: {__name__: h}, histogram: [60, $h]}]
    assert equal ($v | length) 2
    assert equal ($v | last | get value) $h
    assert equal ($v | last | get timestamp) 1970-01-01T00:01:00Z
    let m = promql matrix [{metric: {__name__: h}, histograms: [[0, $h], [60, $h]]}]
    assert equal ($m | length) 2
    assert equal ($m | first | get value) $h
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
    assert equal (promql normalize {resultType: vector, result: [{metric: {__name__: up}, value: [0, "1"]}]}) [{metric: up, timestamp: 1970-01-01T00:00:00Z, value: 1.0}]
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
def "scope builds metric{block}, a bare block, or empty" [] {
    assert equal (promql scope "up" ["job=api"]) 'up{job="api"}'
    assert equal (promql scope null ["job=api"]) '{job="api"}'
    assert equal (promql scope "job=api" ["env!=dev"]) '{job="api", env!="dev"}'   # a leading matcher folds in
    assert equal (promql scope "up" []) "up"
    assert equal (promql scope null []) ""
    assert equal (promql scope "" []) ""
}

@test
def "scope errors on a bare non-matcher sibling" [] {
    assert error { promql scope "up" ["world"] }
}

@test
def "split-tokens separates the first operator-free token from the matchers" [] {
    assert equal (promql split-tokens ["up" "job=api" "status=~5.."]) {metric: up, matchers: ["job=api" "status=~5.."]}
    assert equal (promql split-tokens ["job=api"]) {metric: null, matchers: ["job=api"]}
    assert equal (promql split-tokens ["job=api" "up" "env!=dev"]) {metric: up, matchers: ["job=api" "env!=dev"]}
    assert equal (promql split-tokens []) {metric: null, matchers: []}
}

@test
def "split-tokens strips one pair of surrounding quotes" [] {
    assert equal (promql split-tokens ["'msg=hello world'"]) {metric: null, matchers: ["msg=hello world"]}
    assert equal (promql split-tokens ['"msg=hello world"']) {metric: null, matchers: ["msg=hello world"]}
    assert equal (promql split-tokens ["'up"]) {metric: "'up", matchers: []}   # mismatched quotes are left alone
}

@test
def "matcher-token splits a token into label, operator and value, longest operator first" [] {
    assert equal (promql matcher-token "job=api") {label: job, op: "=", value: api}
    assert equal (promql matcher-token "env!=dev") {label: env, op: "!=", value: dev}
    assert equal (promql matcher-token "status=~5..") {label: status, op: "=~", value: "5.."}
    assert equal (promql matcher-token "status!~5..") {label: status, op: "!~", value: "5.."}
    assert equal (promql matcher-token "path=~/a=b") {label: path, op: "=~", value: "/a=b"}   # operator anchored after the label
    assert equal (promql matcher-token "job=") {label: job, op: "=", value: ""}                # empty value is legal (value-stage trigger)
    assert equal (promql matcher-token "nolabel") null                                         # no operator
    assert equal (promql matcher-token "=api") null                                            # no label
}

@test
def "matchers-tokens builds the block, quoting values, erroring on a bare token" [] {
    assert equal (promql matchers-tokens ["job=api" "status=~5.." "env!=dev"]) '{job="api", status=~"5..", env!="dev"}'
    assert equal (promql matchers-tokens []) ""
    assert equal (promql matchers-tokens ['path=a"b']) '{path="a\"b"}'                          # escapes like `matchers`
    assert error { promql matchers-tokens ["world"] }                                          # a bare non-matcher is a hard error, never a silent drop
}

@test
def "matchers-tokens does not re-quote an already quoted value" [] {
    assert equal (promql matchers-tokens ['job="api"']) '{job="api"}'
    assert equal (promql matchers-tokens ['job=~"api|web"']) '{job=~"api|web"}'
    assert equal (promql matchers-tokens ["job='api'"]) '{job="api"}'
    assert equal (promql matchers-tokens ['job=""']) '{job=""}'                                  # the empty-label match survives
    assert equal (promql scope "up" ['job="api"']) 'up{job="api"}'
}

@test
def "matchers-tokens keeps a quoted value raw: an escaped quote is not re-escaped" [] {
    assert equal (promql matchers-tokens ['path="a\"b"']) '{path="a\"b"}'          # already PromQL-quoted, kept verbatim
    assert equal (promql matchers-tokens ['path=a"b']) '{path="a\"b"}'              # a bare value is escaped for you
    assert equal (promql matchers-tokens ['re=~"5\d\d"']) '{re=~"5\d\d"}'
}

@test
def "matchers-tokens errors on an unquoted comma: one matcher per positional" [] {
    assert error { promql matchers-tokens ["job=api,env=prod"] }
    assert equal (promql matchers-tokens ['job="a,b"']) '{job="a,b"}'                # quoted ⇒ literal comma
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

@test
def "build validates the metric, the grouping labels and the range window" [] {
    assert error { promql build "sum(up)" }                                  # an expression is not a metric name
    assert error { promql build "up" --agg sum --by ["job instance"] }       # a label with a space
    assert error { promql build "up" --range "5" --func rate }               # a unit-less window
    assert equal (promql build "up" --range "5min" --func rate) "rate(up[300s])"     # a Nushell duration spelling renders
    assert equal (promql build "up" --range 5min --func rate) "rate(up[300s])"       # a real duration too
    assert equal (promql build "up" --range "1h30m" --func rate) "rate(up[1h30m])"   # compound PromQL text passes through
}

@test
def "build rejects a range function without a window and a parametric aggregator without --param, unless the dialect disables the check" [] {
    assert error { promql build "up" --func rate }
    assert error { promql build "up" --func max_over_time }
    assert equal (promql build "up" --func rate --range-funcs []) "rate(up)"           # MetricsQL: implicit window
    assert error { promql build "up" --agg topk }
    assert equal (promql build "up" --agg topk --param 5) "topk (5, up)"
    assert equal (promql build "up" --agg quantile --param 0.9 --by [job]) "quantile by (job) (0.9, up)"
    assert error { promql build "up" --param 5 }                                          # a parameter needs an aggregator
    assert ("topk" in (promql param-aggs))
    assert ("rate" in (promql range-funcs))
    assert ("abs" not-in (promql range-funcs))
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

# ---- time range (clock injected) ----------------------------------------------

@test
def "resolve-range resolves --last against the injected now" [] {
    let now = 2023-11-14T22:13:20Z
    assert equal (promql resolve-range 1min null null $now) {start: 2023-11-14T22:12:20Z, end: $now}
    assert equal (promql resolve-range null null null $now) {start: null, end: null}
    # explicit start/end win over --last
    assert equal (promql resolve-range 1min 2020-01-01T00:00:00Z 2020-01-02T00:00:00Z $now) {start: 2020-01-01T00:00:00Z, end: 2020-01-02T00:00:00Z}
    # --last anchors on an explicit --end, not on now
    assert equal (promql resolve-range 1min null 2020-01-02T00:00:00Z $now) {start: 2020-01-01T23:59:00Z, end: 2020-01-02T00:00:00Z}
    # a start-only window stays open by default, and closes at now with --closed
    assert equal (promql resolve-range null 2020-01-01T00:00:00Z null $now) {start: 2020-01-01T00:00:00Z, end: null}
    assert equal (promql resolve-range null 2020-01-01T00:00:00Z null $now --closed) {start: 2020-01-01T00:00:00Z, end: $now}
    # an inverted window is an error, not an empty server result
    assert error { promql resolve-range null 2020-01-02T00:00:00Z 2020-01-01T00:00:00Z $now }
}
