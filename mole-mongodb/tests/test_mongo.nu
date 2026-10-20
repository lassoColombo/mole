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
    assert equal (mongo lit "a\nb") '"a\nb"'      # a control char is escaped, never a raw newline inside the JS string
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

@test
def "coerce-scalar keeps big integers exact and rejects impossible dates" [] {
    assert equal (mongo coerce-scalar "9007199254740992") "9007199254740992"                        # 2^53 is still exact as a JS number
    assert equal (mongo coerce-scalar "9007199254740993") 'NumberLong("9007199254740993")'
    assert equal (mongo coerce-scalar "-9007199254740993") 'NumberLong("-9007199254740993")'
    assert error { mongo coerce-scalar "2026-13-45" }
    assert error { mongo coerce-scalar "2026-02-30" }                                                # plain `into datetime` would roll this to 02-28
    assert error { mongo coerce-scalar "2026-01-02T25:00:00Z" }
    assert equal (mongo coerce-scalar "2028-02-29") 'ISODate("2028-02-29")'                         # leap day is fine
    assert error { mongo coerce-scalar "2026-01-02t03:04:05Z" }                                      # mongosh's ISODate rejects a lowercase t
}

# ---- filter tokens -------------------------------------------------------------

@test
def "parse-filter-token equality and bare" [] {
    assert equal (mongo parse-filter-token "role:admin") '{"role": "admin"}'
    assert equal (mongo parse-filter-token "age:30") '{"age": 30}'
    assert equal (mongo parse-filter-token "active") '{"active": true}'
    assert equal (mongo parse-filter-token "") ""
    assert equal (mongo parse-filter-token "age: 30") '{"age": 30}'      # the value after the colon is trimmed
}

@test
def "parse-filter-token rejects an operator on a bare token" [] {
    assert error { mongo parse-filter-token "age>=30" }    # SQL/PromQL spelling, not field:>=value
    assert error { mongo parse-filter-token "status=done" }
    assert error { mongo build-filter ["sum_amount>=100"] }   # the aggregate --having path too
}

@test
def "parse-filter-token rejects degenerate tokens instead of filtering on nothing" [] {
    assert error { mongo parse-filter-token "role:" }        # the completer offers `role:` — Enter there must not filter on ""
    assert error { mongo parse-filter-token ":admin" }       # no field
    assert error { mongo parse-filter-token "role:in:" }     # empty in-list
    assert error { mongo parse-filter-token "role:in:," }
    assert error { mongo parse-filter-token "age:>=" }       # operator, no value
    assert error { mongo parse-filter-token "name:~" }       # empty regex would match everything
    assert error { mongo parse-filter-token "age:=5" }       # equality has no '='
    assert equal (mongo parse-filter-token "role:in:a,,b") '{"role": {$in: ["a", "b"]}}'   # blank items dropped
}

@test
def "parse-filter-token and sort-spec flatten dotted fields with --flat" [] {
    assert equal (mongo parse-filter-token "address.city:x" --flat) '{"address_city": "x"}'
    assert equal (mongo parse-filter-token "address.city" --flat) '{"address_city": true}'
    assert equal (mongo build-filter ["address.city:x" "count:>=3"] --flat) '{$and: [{"address_city": "x"}, {"count": {$gte: 3}}]}'
    assert equal (mongo build-filter ['{"address.city": 1}'] --flat) '{"address.city": 1}'   # a raw token is verbatim
    assert equal (mongo sort-spec ["address.city desc" "count"] --flat) '{"address_city": -1, "count": 1}'
    assert equal (mongo sort-spec ["address.city"]) '{"address.city": 1}'                   # find keeps dotted paths
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
    assert error { mongo projection-spec [name] [bytes] }   # Mongo can't mix include and exclude; neither may silently win
}

@test
def "sort-spec renders directions" [] {
    assert equal (mongo sort-spec ["age"]) '{"age": 1}'
    assert equal (mongo sort-spec ["age desc" "name"]) '{"age": -1, "name": 1}'
    assert equal (mongo sort-spec ["age ASC"]) '{"age": 1}'
    assert equal (mongo sort-spec []) null
    assert equal (mongo sort-spec ["age:desc" "name:asc"]) '{"age": -1, "name": 1}'   # the SQL drivers' spelling works too
    assert equal (mongo sort-spec ["address.city:DESC"]) '{"address.city": -1}'
    assert error { mongo sort-spec ["age:dsc"] }                                       # a typo must not silently sort ascending
    assert error { mongo sort-spec ["age dsc"] }
}

# ---- find builder --------------------------------------------------------------

@test
def "build-find composes clauses" [] {
    assert equal (mongo build-find "users" "{}") 'db.getCollection("users").find({}).toArray()'
    assert equal (
        mongo build-find "users" '{"age": {$gte: 30}}' --project '{"name": 1, "_id": 0}' --sort '{"age": -1}' --limit 5 --skip 10
    ) 'db.getCollection("users").find({"age": {$gte: 30}}, {"name": 1, "_id": 0}).sort({"age": -1}).skip(10).limit(5).toArray()'
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
    # the legacy write methods mongosh still executes, and command-level / admin writes
    assert equal ("db.users.insert({a:1})" =~ $re) true
    assert equal ("db.users.update({}, {$set: {a: 1}})" =~ $re) true
    assert equal ('db.runCommand({drop: "users"})' =~ $re) true
    assert equal ('db.adminCommand({shutdown: 1})' =~ $re) true
    assert equal ('db.createUser({user: "x"})' =~ $re) true
    assert equal ('db.dropUser("x")' =~ $re) true
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
def "parse-agg-token rejects what it would otherwise silently drop or splice raw" [] {
    assert error {|| mongo parse-agg-token "count:amount" }         # count takes no field (would count everything)
    assert error {|| mongo parse-agg-token "sum:amount:5" }         # sum takes no param
    assert error {|| mongo parse-agg-token "median:x:0.5" }
    assert error {|| mongo parse-agg-token "maxN:amount:abc" }      # N is spliced into JS: must be an int
    assert error {|| mongo parse-agg-token "maxN:amount:5}}]).toArray();db.dropDatabase();[]//" }
    assert error {|| mongo parse-agg-token "percentile:latency:abc" }
    assert error {|| mongo parse-agg-token "percentile:latency:95" }  # p is a fraction
    assert error {|| mongo parse-agg-token "maxN:amount:5:extra" }  # a fourth part
}

@test
def "result-cols names keys then aliases, in order, like the pipeline" [] {
    assert equal (mongo result-cols [address.city] "created:day" ["count" "sum:amount=total"]) [address_city created count total]
    assert equal (mongo result-cols [] null []) []
    assert equal (mongo result-cols [status] null ["count" "bogus:x"]) [status count]   # lenient: a half-typed agg still completes
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
    ) 'db.getCollection("orders").aggregate([{$unwind: "$items"}, {$group: {_id: {"items_sku": "$items.sku"}, "count": {$sum: 1}}}, {$project: {"_id": 0, "items_sku": "$_id.items_sku", "count": 1}}]).toArray()'

    # date bucket
    assert equal (
        mongo build-pipeline "events" --date-bucket "created:hour" --agg ["count"]
    ) 'db.getCollection("events").aggregate([{$group: {_id: {"created": {$dateTrunc: {date: "$created", unit: "hour"}}}, "count": {$sum: 1}}}, {$project: {"_id": 0, "created": "$_id.created", "count": 1}}]).toArray()'
}

@test
def "build-pipeline flattens dotted group keys" [] {
    # `_id` field names may not contain a dot; the key is named like an accumulator alias
    assert equal (
        mongo build-pipeline "users" --by [address.city] --agg ["count"]
    ) 'db.getCollection("users").aggregate([{$group: {_id: {"address_city": "$address.city"}, "count": {$sum: 1}}}, {$project: {"_id": 0, "address_city": "$_id.address_city", "count": 1}}]).toArray()'
    assert equal (
        mongo build-pipeline "events" --date-bucket "meta.created:day"
    ) 'db.getCollection("events").aggregate([{$group: {_id: {"meta_created": {$dateTrunc: {date: "$meta.created", unit: "day"}}}}}, {$project: {"_id": 0, "meta_created": "$_id.meta_created"}}]).toArray()'
    assert error { mongo build-pipeline "users" --by [address.city] --agg ["count=address_city"] }   # the flat name is what clashes
}

@test
def "build-pipeline rejects a result column defined twice" [] {
    assert error { mongo build-pipeline "orders" --by [status] --agg ["count=status"] }   # alias would overwrite the group key
    assert error { mongo build-pipeline "orders" --agg ["sum:amount" "sum:amount"] }
    assert error { mongo build-pipeline "orders" --agg ["count" "sum:amount=count"] }
    assert error { mongo build-pipeline "orders" --by [status] --agg ["count=_id"] }      # `_id` holds the keys; JS last-key-wins would drop them
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
