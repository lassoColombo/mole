use std/assert
use std/testing *
use ../logsql.nu

# ---- scalar coercions ---------------------------------------------------------

@test
def "num coerces stats sample-value strings" [] {
    assert equal (logsql num "3.14") 3.14
    assert equal (logsql num "0") 0.0
    assert equal (logsql num "NaN") null          # Nushell has no NaN literal
    assert equal (logsql num 5) 5                  # non-strings pass through untouched
}

@test
def "epoch converts unix seconds to datetime" [] {
    assert equal (logsql epoch 0) 1970-01-01T00:00:00Z
    assert equal (logsql epoch 1704067200) 2024-01-01T00:00:00Z
}

@test
def "rfc3339 parses a string to datetime, keeping unparseable input" [] {
    assert equal (logsql rfc3339 "2024-01-01T00:00:00Z") 2024-01-01T00:00:00Z
    assert equal (logsql rfc3339 "not-a-time") "not-a-time"
}

@test
def "vl-time renders an RFC3339 UTC string, null-safe" [] {
    assert equal (logsql vl-time 2024-01-01T00:00:00Z) "2024-01-01T00:00:00.000000000Z"
    assert equal (logsql vl-time null) null
}

@test
def "step renders integer seconds, null-safe" [] {
    assert equal (logsql step 1hr) "3600s"
    assert equal (logsql step 30min) "1800s"
    assert equal (logsql step 15sec) "15s"
    assert equal (logsql step null) null
}

# ---- query (JSONL) ------------------------------------------------------------

@test
def "jsonl parses one row per non-blank line" [] {
    let body = "{\"_time\":\"2024-01-01T00:00:00Z\",\"_msg\":\"a\"}\n\n{\"_time\":\"2024-01-01T00:00:01Z\",\"_msg\":\"b\"}\n"
    let out = logsql jsonl $body
    assert equal ($out | length) 2
    assert equal ($out | first) {_time: "2024-01-01T00:00:00Z", _msg: a}
    assert equal ($out | first | get _time | describe) "string"   # jsonl leaves values raw
}

@test
def "coerce-time types the _time column and leaves others as strings" [] {
    let out = logsql coerce-time [{_time: "2024-01-01T00:00:00Z", _msg: hi, level: error}]
    assert equal ($out | first | get _time) 2024-01-01T00:00:00Z
    assert equal ($out | first | get _time | describe) "datetime"
    assert equal ($out | first | get level) "error"               # untouched
}

@test
def "coerce-time is a no-op when there is no _time column" [] {
    assert equal (logsql coerce-time [{a: 1}]) [{a: 1}]
    assert equal (logsql coerce-time []) []
}

@test
def "query parses and types a JSONL body end to end" [] {
    let out = logsql query "{\"_time\":\"2024-01-01T00:00:00Z\",\"_msg\":\"hi\",\"level\":\"error\"}"
    assert equal $out [{_time: 2024-01-01T00:00:00Z, _msg: hi, level: error}]
}

# ---- hits ---------------------------------------------------------------------

@test
def "hits pivots grouped series into tidy rows" [] {
    let out = logsql hits {hits: [{fields: {level: error}, timestamps: ["2024-01-01T00:00:00Z", "2024-01-01T01:00:00Z"], values: [3, 5]}]}
    assert equal ($out | length) 2
    assert equal ($out | first) {time: 2024-01-01T00:00:00Z, level: error, hits: 3}
    assert equal ($out | last | get hits) 5
}

@test
def "hits handles an ungrouped series and empty payloads" [] {
    let out = logsql hits {hits: [{fields: {}, timestamps: ["2024-01-01T00:00:00Z"], values: [7]}]}
    assert equal $out [{time: 2024-01-01T00:00:00Z, hits: 7}]
    assert equal (logsql hits {hits: []}) []
}

# ---- stats (Prometheus-shaped) ------------------------------------------------

@test
def "relabel surfaces __name__ as metric, defaulting to value" [] {
    assert equal (logsql relabel {__name__: "count(*)", level: info}) {level: info, metric: "count(*)"}
    assert equal (logsql relabel {level: info}) {level: info, metric: value}
}

@test
def "stats-vector yields one typed row per series" [] {
    let out = logsql stats-vector [{metric: {__name__: "count(*)", level: info}, value: [1704153600, "42"]}]
    assert equal $out [{level: info, metric: "count(*)", value: 42.0}]
}

@test
def "stats-matrix yields tidy rows, one per point" [] {
    let out = logsql stats-matrix [{metric: {__name__: "count(*)"}, values: [[1704067200, "10"], [1704070800, "20"]]}]
    assert equal ($out | length) 2
    assert equal ($out | first) {metric: "count(*)", time: 2024-01-01T00:00:00Z, value: 10.0}
    assert equal ($out | last | get value) 20.0
}

@test
def "stats unwraps an instant envelope and types it" [] {
    let resp = {status: success, data: {resultType: vector, result: [{metric: {__name__: "count(*)"}, value: [0, "7"]}]}}
    assert equal (logsql stats $resp) [{metric: "count(*)", value: 7.0}]
}

@test
def "stats-range unwraps a range envelope and types it" [] {
    let resp = {status: success, data: {resultType: matrix, result: [{metric: {__name__: "count(*)"}, values: [[0, "1"]]}]}}
    assert equal (logsql stats-range $resp) [{metric: "count(*)", time: 1970-01-01T00:00:00Z, value: 1.0}]
}

# ---- value / stream enumeration ----------------------------------------------

@test
def "values passes through record rows and normalizes bare strings" [] {
    assert equal (logsql values {values: [{value: host-1, hits: 3}, {value: host-2, hits: 5}]}) [{value: host-1, hits: 3}, {value: host-2, hits: 5}]
    assert equal (logsql values {values: ["a", "b"]}) [{value: a, hits: null}, {value: b, hits: null}]
    assert equal (logsql values {values: []}) []
}

# ---- facets -------------------------------------------------------------------

@test
def "facets renames field_name and field_value to the tidy shape" [] {
    let out = logsql facets {facets: [{field_name: level, values: [{field_value: error, hits: 4}, {field_value: info, hits: 9}]}]}
    assert equal ($out | length) 1
    assert equal ($out | first | get field) "level"
    assert equal ($out | first | get values) [{value: error, hits: 4}, {value: info, hits: 9}]
}
