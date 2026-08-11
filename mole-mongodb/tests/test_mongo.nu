use std/assert
use std/testing *
use ../mongo.nu

# ---- JS literals ---------------------------------------------------------------

@test
def "lit quotes and escapes" [] {
    assert equal (mongo lit "active") '"active"'
    assert equal (mongo lit "address.city") '"address.city"'
    assert equal (mongo lit 'a"b') '"a\"b"'
    assert equal (mongo lit 'a\b') '"a\\b"'
}

@test
def "coerce-scalar types bare values" [] {
    assert equal (mongo coerce-scalar "30") "30"
    assert equal (mongo coerce-scalar "0") "0"
    assert equal (mongo coerce-scalar "-5") "-5"
    assert equal (mongo coerce-scalar "007") '"007"'          # leading zero → identifier string
    assert equal (mongo coerce-scalar "99999999999999999999999") '"99999999999999999999999"'  # i64 overflow → string
    assert equal (mongo coerce-scalar "12.5") "12.5"
    assert equal (mongo coerce-scalar "true") "true"
    assert equal (mongo coerce-scalar "false") "false"
    assert equal (mongo coerce-scalar "null") "null"
    assert equal (mongo coerce-scalar "2026-01-02") 'ISODate("2026-01-02")'
    assert equal (mongo coerce-scalar "2026-01-02T03:04:05Z") 'ISODate("2026-01-02T03:04:05Z")'
    assert equal (mongo coerce-scalar "admin") '"admin"'
}

# ---- filter tokens -------------------------------------------------------------

@test
def "parse-filter-token equality and bare" [] {
    assert equal (mongo parse-filter-token "role:admin") '{"role": "admin"}'
    assert equal (mongo parse-filter-token "age:30") '{"age": 30}'
    assert equal (mongo parse-filter-token "active") '{"active": true}'
    assert equal (mongo parse-filter-token "") ""
}

@test
def "parse-filter-token comparisons" [] {
    assert equal (mongo parse-filter-token "age:>=30") '{"age": {$gte: 30}}'
    assert equal (mongo parse-filter-token "age:>30") '{"age": {$gt: 30}}'
    assert equal (mongo parse-filter-token "age:<=30") '{"age": {$lte: 30}}'
    assert equal (mongo parse-filter-token "age:<30") '{"age": {$lt: 30}}'
    assert equal (mongo parse-filter-token "status:!=done") '{"status": {$ne: "done"}}'
}

@test
def "parse-filter-token in-list and regex" [] {
    assert equal (mongo parse-filter-token "role:in:admin,ops") '{"role": {$in: ["admin", "ops"]}}'
    assert equal (mongo parse-filter-token "name:~/^a/i") '{"name": {$regex: "^a", $options: "i"}}'
    assert equal (mongo parse-filter-token "name:~abc") '{"name": {$regex: "abc"}}'
}

@test
def "parse-filter-token raw json is verbatim" [] {
    assert equal (mongo parse-filter-token '{$expr: {$gt: ["$a", "$b"]}}') '{$expr: {$gt: ["$a", "$b"]}}'
}

@test
def "build-filter joins with and" [] {
    assert equal (mongo build-filter []) "{}"
    assert equal (mongo build-filter ["role:admin"]) '{"role": "admin"}'
    assert equal (mongo build-filter ["role:admin" "age:>=30"]) '{$and: [{"role": "admin"}, {"age": {$gte: 30}}]}'
    assert equal (mongo build-filter ["" "role:admin" ""]) '{"role": "admin"}'   # blanks dropped
}

# ---- projection / sort ---------------------------------------------------------

@test
def "projection-spec include drops _id unless asked" [] {
    assert equal (mongo projection-spec [name email] []) '{"name": 1, "email": 1, "_id": 0}'
    assert equal (mongo projection-spec [_id name] []) '{"_id": 1, "name": 1}'
    assert equal (mongo projection-spec [] [bytes _stream_id]) '{"bytes": 0, "_stream_id": 0}'
    assert equal (mongo projection-spec [] []) null
}

@test
def "sort-spec renders directions" [] {
    assert equal (mongo sort-spec ["age"]) '{"age": 1}'
    assert equal (mongo sort-spec ["age desc" "name"]) '{"age": -1, "name": 1}'
    assert equal (mongo sort-spec ["age ASC"]) '{"age": 1}'
    assert equal (mongo sort-spec []) null
}

# ---- find builder --------------------------------------------------------------

@test
def "build-find composes clauses" [] {
    assert equal (mongo build-find "users" "{}") 'db.getCollection("users").find({}).toArray()'
    assert equal (
        mongo build-find "users" '{"age": {$gte: 30}}' --project '{"name": 1, "_id": 0}' --sort '{"age": -1}' --limit 5 --skip 10
    ) 'db.getCollection("users").find({"age": {$gte: 30}}, {"name": 1, "_id": 0}).sort({"age": -1}).skip(10).limit(5).toArray()'
}

# ---- completion helper ---------------------------------------------------------

@test
def "parse-flag reads flags from a context line" [] {
    assert equal (mongo parse-flag "find -C orders --limit 5" ["--collection" "-C"]) "orders"
    assert equal (mongo parse-flag "find --collection=orders" ["--collection" "-C"]) "orders"
    assert equal (mongo parse-flag "find -C a -C b" ["--collection" "-C"]) "b"   # last wins
    assert equal (mongo parse-flag "find" ["--collection" "-C"]) null
}

# ---- safety --------------------------------------------------------------------

@test
def "mongo-danger flags write ops, not reads" [] {
    let re = (mongo mongo-danger)
    # the pattern classifies mongosh methods + pipeline write stages; the generic
    # string-blanking guard (`query is-dangerous`) is covered in mole/tests/test_query
    assert equal ("db.users.deleteMany({})" =~ $re) true
    assert equal ("db.users.insertOne({a:1})" =~ $re) true
    assert equal ("db.users.drop()" =~ $re) true
    assert equal ("db.orders.aggregate([{$out: 'copy'}])" =~ $re) true
    assert equal ("db.users.find({})" =~ $re) false
    assert equal ("db.users.countDocuments({})" =~ $re) false
}

# ---- aggregate building --------------------------------------------------------

@test
def "stat-alias sanitizes" [] {
    assert equal (mongo stat-alias "latency") "latency"
    assert equal (mongo stat-alias "meta.latency") "meta_latency"
}

@test
def "parse-agg-token parses functions, fields, params, aliases" [] {
    assert equal (mongo parse-agg-token "count") {alias: "count", accumulator: "{$sum: 1}"}
    assert equal (mongo parse-agg-token "sum:amount") {alias: "sum_amount", accumulator: '{$sum: "$amount"}'}
    assert equal (mongo parse-agg-token "avg:meta.latency") {alias: "avg_meta_latency", accumulator: '{$avg: "$meta.latency"}'}
    assert equal (mongo parse-agg-token "maxN:amount:5") {alias: "maxN_amount", accumulator: '{$maxN: {input: "$amount", n: 5}}'}
    assert equal (mongo parse-agg-token "percentile:latency:0.95=p95") {alias: "p95", accumulator: '{$percentile: {input: "$latency", p: [0.95], method: "approximate"}}'}
    assert equal (mongo parse-agg-token "sum:amount=total") {alias: "total", accumulator: '{$sum: "$amount"}'}
}

@test
def "parse-agg-token rejects unknown functions and missing args" [] {
    assert error {|| mongo parse-agg-token "bogus:x" }
    assert error {|| mongo parse-agg-token "sum" }          # needs a field
    assert error {|| mongo parse-agg-token "maxN:amount" }  # needs N
    assert error {|| mongo parse-agg-token "percentile:latency" }  # needs p
}

@test
def "build-pipeline composes group, project, having, sort" [] {
    assert equal (
        mongo build-pipeline "orders" --by [customer] --agg ["count"]
    ) 'db.getCollection("orders").aggregate([{$group: {_id: {"customer": "$customer"}, "count": {$sum: 1}}}, {$project: {"_id": 0, "customer": "$_id.customer", "count": 1}}]).toArray()'

    assert equal (
        mongo build-pipeline "orders" --match '{"active": true}' --by [customer] --agg ["count" "sum:amount"] --having '{"sum_amount": {$gte: 1000}}' --sort '{"sum_amount": -1}' --limit 10
    ) 'db.getCollection("orders").aggregate([{$match: {"active": true}}, {$group: {_id: {"customer": "$customer"}, "count": {$sum: 1}, "sum_amount": {$sum: "$amount"}}}, {$project: {"_id": 0, "customer": "$_id.customer", "count": 1, "sum_amount": 1}}, {$match: {"sum_amount": {$gte: 1000}}}, {$sort: {"sum_amount": -1}}, {$limit: 10}]).toArray()'
}

@test
def "build-pipeline supports by-only, unwind and date buckets" [] {
    # by-only: no accumulators → distinct group combinations
    assert equal (
        mongo build-pipeline "orders" --by [customer region]
    ) 'db.getCollection("orders").aggregate([{$group: {_id: {"customer": "$customer", "region": "$region"}}}, {$project: {"_id": 0, "customer": "$_id.customer", "region": "$_id.region"}}]).toArray()'

    # group everything (no keys) → _id: null
    assert equal (
        mongo build-pipeline "orders" --agg ["sum:amount"]
    ) 'db.getCollection("orders").aggregate([{$group: {_id: null, "sum_amount": {$sum: "$amount"}}}, {$project: {"_id": 0, "sum_amount": 1}}]).toArray()'

    # unwind before group
    assert equal (
        mongo build-pipeline "orders" --unwind items --by [items.sku] --agg ["count"]
    ) 'db.getCollection("orders").aggregate([{$unwind: "$items"}, {$group: {_id: {"items.sku": "$items.sku"}, "count": {$sum: 1}}}, {$project: {"_id": 0, "items.sku": "$_id.items.sku", "count": 1}}]).toArray()'

    # date bucket
    assert equal (
        mongo build-pipeline "events" --date-bucket "created:hour" --agg ["count"]
    ) 'db.getCollection("events").aggregate([{$group: {_id: {"created": {$dateTrunc: {date: "$created", unit: "hour"}}}, "count": {$sum: 1}}}, {$project: {"_id": 0, "created": "$_id.created", "count": 1}}]).toArray()'
}

# ---- Extended JSON decode ------------------------------------------------------

@test
def "ejson-decode maps scalar BSON wrappers" [] {
    assert equal (mongo ejson-decode {"$oid": "64b7f0f0f0f0f0f0f0f0f0f0"}) "64b7f0f0f0f0f0f0f0f0f0f0"
    assert equal (mongo ejson-decode {"$numberInt": "42"}) 42
    assert equal (mongo ejson-decode {"$numberLong": "9007199254740993"}) 9007199254740993   # > 2^53, exact
    assert equal (mongo ejson-decode {"$numberDouble": "3.14"}) 3.14
    assert equal (mongo ejson-decode {"$numberDouble": "NaN"}) null
    assert equal (mongo ejson-decode {"$numberDouble": "Infinity"}) null
    assert equal (mongo ejson-decode {"$numberDecimal": "1.50"}) "1.50"   # kept exact as string
}

@test
def "ejson-decode maps dates both canonical and relaxed" [] {
    assert equal (mongo ejson-decode {"$date": {"$numberLong": "1767323045678"}}) 2026-01-02T03:04:05.678Z
    assert equal (mongo ejson-decode {"$date": {"$numberLong": "0"}}) 1970-01-01T00:00:00Z
    assert equal (mongo ejson-decode {"$date": "2024-01-01T00:00:00Z"}) 2024-01-01T00:00:00Z   # relaxed
}

@test
def "ejson-decode maps binary, timestamp, regex" [] {
    assert equal (mongo ejson-decode {"$binary": {base64: "aGVsbG8=", subType: "00"}}) {base64: "aGVsbG8=", subType: "00"}
    assert equal (mongo ejson-decode {"$timestamp": {t: 1700000000, i: 1}}) {t: 1700000000, i: 1}
    assert equal (mongo ejson-decode {"$regularExpression": {pattern: "^a", options: "i"}}) "/^a/i"
}

@test
def "ejson-decode recurses documents and arrays" [] {
    assert equal (mongo ejson-decode {a: {"$numberInt": "1"}, b: [{"$numberInt": "2"}, {"$numberInt": "3"}]}) {a: 1, b: [2, 3]}
    # a whole document with mixed types (a decoded find row)
    let doc = {
        _id: {"$oid": "64b7f0f0f0f0f0f0f0f0f0f0"}
        when: {"$date": {"$numberLong": "0"}}
        n: {"$numberInt": "5"}
        nested: {city: "NYC", tags: [{"$numberInt": "1"}]}
        active: true
        note: null
    }
    assert equal (mongo ejson-decode $doc) {
        _id: "64b7f0f0f0f0f0f0f0f0f0f0"
        when: 1970-01-01T00:00:00Z
        n: 5
        nested: {city: "NYC", tags: [1]}
        active: true
        note: null
    }
    # a result array (what .toArray() yields) decodes to a table
    assert equal (mongo ejson-decode [{a: {"$numberInt": "1"}}, {a: {"$numberInt": "2"}}]) [{a: 1}, {a: 2}]
}

@test
def "ejson-decode passes plain scalars through" [] {
    assert equal (mongo ejson-decode "hi") "hi"
    assert equal (mongo ejson-decode true) true
    assert equal (mongo ejson-decode null) null
}

# ---- schema inference ----------------------------------------------------------

@test
def "observe reports type sets and nullability" [] {
    assert equal (mongo observe [1 2 3]) {types: [int], nullable: false}
    assert equal (mongo observe [1 "a"]) {types: [int, string], nullable: false}   # mixed → both, sorted
    assert equal (mongo observe [1 null]) {types: [int], nullable: true}
    assert equal (mongo observe []) {types: [], nullable: false}
    assert equal (mongo observe [2026-01-01T00:00:00Z]) {types: [datetime], nullable: false}
}

@test
def "infer-schema reports fields, occurrence, mixed types" [] {
    assert equal (
        mongo infer-schema [{name: "a", age: 30} {name: "b"}]
    ) [
        {name: age, types: [int], nullable: true, occurrence: 50}
        {name: name, types: [string], nullable: false, occurrence: 100}
    ]
    # a field with different types across docs
    assert equal (
        mongo infer-schema [{v: 1} {v: "x"}] | first
    ) {name: v, types: [int, string], nullable: false, occurrence: 100}
}

@test
def "infer-schema flattens nested docs and arrays to dotted paths" [] {
    assert equal (
        mongo infer-schema [{addr: {city: "x"}, items: [{sku: "a"} {sku: "b"}]}] | get name
    ) [addr, addr.city, items, items.sku]
    # the array container is a list; its element field is typed by the elements
    let s = (mongo infer-schema [{items: [{sku: "a"} {sku: "b"}]}])
    assert equal ($s | where name == "items" | get 0.types) [list]
    assert equal ($s | where name == "items.sku" | get 0.types) [string]
}
