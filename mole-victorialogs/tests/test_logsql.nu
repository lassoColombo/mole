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
def "col-kind infers a column type all-or-nothing" [] {
    assert equal (logsql col-kind ["500" "200" "0"]) "int"
    assert equal (logsql col-kind ["-5" "7"]) "int"
    assert equal (logsql col-kind ["007" "012"]) "string"                    # leading zeros = ids
    assert equal (logsql col-kind ["123456789012345678901234"]) "string"    # i64 overflow (into int saturates)
    assert equal (logsql col-kind ["12.5" "0.4"]) "float"
    assert equal (logsql col-kind ["5" "12.5"]) "float"                      # int + decimal → float
    assert equal (logsql col-kind ["true" "false"]) "bool"
    assert equal (logsql col-kind ["2026-08-10T10:00:00Z" "2026-08-10T11:00:00Z"]) "datetime"
    assert equal (logsql col-kind ["[1,2]" "[3]"]) "json"
    assert equal (logsql col-kind ["500" "n/a"]) "string"                    # one misfit
    assert equal (logsql col-kind []) "string"                              # no evidence
}

@test
def "cast converts a cell and nulls the empty" [] {
    assert equal (logsql cast "500" "int") 500
    assert equal (logsql cast "12.5" "float") 12.5
    assert equal (logsql cast "true" "bool") true
    assert equal (logsql cast "[1,2]" "json") [1 2]
    assert equal (logsql cast "2026-08-10T10:00:00Z" "datetime") 2026-08-10T10:00:00Z
    assert equal (logsql cast '{host="h1"}' "stream") {host: h1}
    assert equal (logsql cast "" "int") null
    assert equal (logsql cast null "int") null
}

@test
def "parse-stream turns a selector into a record, handling quotes and commas" [] {
    assert equal (logsql parse-stream '{app="worker",host="h2"}') {app: worker, host: h2}
    assert equal (logsql parse-stream '{host="h,3"}') {host: "h,3"}          # comma inside a quoted value
    assert equal (logsql parse-stream '{app="a\"b"}') {app: 'a"b'}           # escaped quote
    assert equal (logsql parse-stream "{}") {}                               # empty selector
    assert equal (logsql parse-stream "not-a-selector") "not-a-selector"     # unparseable → unchanged
}

@test
def "type-rows types generic columns and respects reserved fields" [] {
    let out = (logsql type-rows [
        {_time: "2026-08-10T10:00:00Z", _msg: "500", _stream: '{host="h1"}', status: "500", cached: "true", "tags.n": "3"}
        {_time: "2026-08-10T10:00:01Z", _msg: "ok",  _stream: '{host="h2"}', status: "200", cached: "false", "tags.n": "4"}
    ])
    let r = ($out | first)
    assert equal ($r._time | describe) "datetime"
    assert equal ($r._msg) "500"                # _msg reserved → stays a string even when numeric
    assert equal ($r._stream) {host: h1}        # _stream selector → record of labels
    assert equal ($r.status) 500                # generic numeric → int
    assert equal ($r.cached) true               # bool
    assert equal ($r | get "tags.n") 3          # VL dotted key matched literally → int
}

@test
def "type-rows keeps a mixed column as strings and preserves sparse rows" [] {
    let out = (logsql type-rows [{a: "1", b: "x"} {a: "nope"}])
    assert equal ($out | get a) ["1" "nope"]    # column a not all-int → string
    assert equal ($out | first | get b) "x"
    assert equal ($out | last | columns) ["a"]  # sparse row unchanged (no b)
    assert equal (logsql type-rows []) []
}

@test
def "query parses and types a JSONL body end to end" [] {
    let out = logsql query "{\"_time\":\"2024-01-01T00:00:00Z\",\"_msg\":\"hi\",\"level\":\"error\",\"status\":\"500\"}"
    assert equal $out [{_time: 2024-01-01T00:00:00Z, _msg: hi, level: error, status: 500}]
}

@test
def "shape projects rows to the requested verbosity" [] {
    let rows = [{_time: 2024-01-01T00:00:00Z, _msg: hi, _stream: {host: h1}, _stream_id: "00", level: error, status: 500}]
    assert equal (logsql shape $rows "full") $rows                                          # untouched
    # wide drops only the internal _stream_id
    assert equal (logsql shape $rows "wide") [{_time: 2024-01-01T00:00:00Z, _msg: hi, _stream: {host: h1}, level: error, status: 500}]
    # compact keeps the triage essentials, in priority order
    assert equal (logsql shape $rows "compact") [{_time: 2024-01-01T00:00:00Z, level: error, _stream: {host: h1}, _msg: hi}]
    # unknown mode → compact
    assert equal (logsql shape $rows "bogus") [{_time: 2024-01-01T00:00:00Z, level: error, _stream: {host: h1}, _msg: hi}]
}

@test
def "shape compact is adaptive and handles edge shapes" [] {
    # only the essentials actually present are kept (no null `level`/`_stream` fabricated)
    assert equal (logsql shape [{_time: 2024-01-01T00:00:00Z, _msg: hi, host: h1}] "compact") [{_time: 2024-01-01T00:00:00Z, _msg: hi}]
    # rows are rectangular over the kept essentials; a sparse row gets nulls for the missing ones
    assert equal (logsql shape [{_time: 2024-01-01T00:00:00Z, level: error, _msg: a} {_msg: b}] "compact") [{_time: 2024-01-01T00:00:00Z, level: error, _msg: a} {_time: null, level: null, _msg: b}]
    # no essentials present → rows pass through untouched
    assert equal (logsql shape [{foo: 1}] "compact") [{foo: 1}]
    assert equal (logsql shape [] "compact") []
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

# ---- query building (composable `search`) -------------------------------------

@test
def "lit leaves bare-safe words alone and quotes the rest" [] {
    assert equal (logsql lit "error") "error"
    assert equal (logsql lit "web-1.host") "web-1.host"
    assert equal (logsql lit "*") "*"
    assert equal (logsql lit "web server") '"web server"'
    assert equal (logsql lit 'say "hi"') '"say \"hi\""'
}

@test
def "has-pipe detects only top-level pipes, not quoted ones" [] {
    assert equal (logsql has-pipe "level:error") false
    assert equal (logsql has-pipe "level:error | stats count()") true
    assert equal (logsql has-pipe 'app:~"api|web"') false            # regex alternation in double quotes
    assert equal (logsql has-pipe "_msg:'a|b'") false                # single-quoted phrase
    assert equal (logsql has-pipe '_msg:`a|b`') false                # backtick-quoted phrase
    assert equal (logsql has-pipe 'app:~"api|web" | stats count()') true   # a quoted pipe AND a real one
    assert equal (logsql has-pipe '_msg:"say \"hi\" | bye"') false    # escaped quotes inside; pipe is data
}

@test
def "build-pipeline assembles filter plus stages in order" [] {
    assert equal (logsql build-pipeline "level:error") "level:error"
    assert equal (logsql build-pipeline "" --limit 10) "* | limit 10"
    assert equal (
        logsql build-pipeline "level:error" --fields [_time _msg host] --sort-by [_time] --limit 100
    ) "level:error | fields _time, _msg, host | sort by (_time) | limit 100"
    # multi-field sort, descending
    assert equal (
        logsql build-pipeline "*" --sort-by [_time host] --desc
    ) "* | sort by (_time, host) desc"
    # --desc without sort fields is a no-op (no sort stage emitted)
    assert equal (logsql build-pipeline "level:error" --desc) "level:error"
    # drop stage (inverse of fields)
    assert equal (logsql build-pipeline "level:error" --drop [_stream_id bytes]) "level:error | delete _stream_id, bytes"
    # stream_context: either side alone, or both
    assert equal (logsql build-pipeline "error" --context-after 2) "error | stream_context after 2"
    assert equal (logsql build-pipeline "error" --context-before 1 --context-after 2) "error | stream_context before 1 after 2"
    # full stage order: filter | stream_context | fields | delete | sort | limit
    assert equal (
        logsql build-pipeline "level:error" --context-after 1 --fields [_time _msg host] --sort-by [_time] --desc --limit 5
    ) "level:error | stream_context after 1 | fields _time, _msg, host | sort by (_time) desc | limit 5"
}

# ---- stats building (composable `stats`) --------------------------------------

@test
def "stat-alias sanitizes field names into result-name suffixes" [] {
    assert equal (logsql stat-alias "latency_ms") "latency_ms"
    assert equal (logsql stat-alias "tags.n") "tags_n"       # VL flattened dotted key
    assert equal (logsql stat-alias "a-b.c") "a_b_c"
}

@test
def "build-stats puts the by-clause before the functions" [] {
    assert equal (logsql build-stats "*" --aggs [{expr: "count()", name: "count"}]) "* | stats count() as count"
    assert equal (logsql build-stats "" --aggs [{expr: "count()", name: "count"}]) "* | stats count() as count"   # empty filter → *
    # grouped, multi-aggregation — `by (...)` precedes the functions (the syntax this VL build wants)
    assert equal (
        logsql build-stats "level:error" --by [host] --aggs [{expr: "count()", name: "count"} {expr: "avg(latency_ms)", name: "avg_latency_ms"}]
    ) "level:error | stats by (host) count() as count, avg(latency_ms) as avg_latency_ms"
    # post-stats top-N over a result column
    assert equal (
        logsql build-stats "*" --by [host] --aggs [{expr: "count()", name: "count"}] --sort-by [count] --desc --limit 10
    ) "* | stats by (host) count() as count | sort by (count) desc | limit 10"
    # --desc without a sort field emits no sort stage
    assert equal (logsql build-stats "*" --aggs [{expr: "count()", name: "count"}] --desc) "* | stats count() as count"
    # a multi-field by-clause carries bucket syntax verbatim
    assert equal (
        logsql build-stats "*" --by ["_time:1h" level] --aggs [{expr: "count()", name: "count"}]
    ) "* | stats by (_time:1h, level) count() as count"
}

@test
def "stats-wide pivots tidy rows into one wide row per group" [] {
    # a column per aggregation; the result is rectangular (a group missing one gets null)
    let long = [
        {level: error, metric: count, value: 2}
        {level: error, metric: avg_bytes, value: 512.0}
        {level: info, metric: count, value: 3}
    ]
    assert equal (logsql stats-wide $long --keys [level] --cols [count avg_bytes]) [
        {level: error, count: 2, avg_bytes: 512.0}
        {level: info, count: 3, avg_bytes: null}
    ]
}

@test
def "stats-wide preserves group order and leads with time for a series" [] {
    # first-seen group order is kept, so a server-side top-N sort/limit survives the pivot
    assert equal (
        logsql stats-wide [{host: h2, metric: count, value: 5} {host: h1, metric: count, value: 3}] --keys [host] --cols [count]
    ) [{host: h2, count: 5} {host: h1, count: 3}]
    # range: `time` is a key column, led first
    assert equal (
        logsql stats-wide [{level: error, metric: count, value: 2, time: 2024-01-01T00:00:00Z}] --keys [time level] --cols [count]
    ) [{time: 2024-01-01T00:00:00Z, level: error, count: 2}]
}

@test
def "stats-wide passes non-stats input through unchanged" [] {
    assert equal (logsql stats-wide []) []
    assert equal (logsql stats-wide "nope") "nope"
    assert equal (logsql stats-wide [{a: 1}]) [{a: 1}]        # no `metric` column → not stats-shaped
}

