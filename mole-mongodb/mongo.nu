# mole-mongodb/mongo — PURE transform + query-building helpers for the MongoDB
# plugin. Data-in / data-out: NO I/O, NO clock, NO connection. This file `use`s
# NOTHING, so it is unit-testable in isolation (tests/test_mongo.nu) and
# nu-checkable standalone. mod.nu imports it PRIVATELY (`use ./mongo.nu`); nothing
# here leaks into `use mole-mongodb`.
#
# It owns: the ergonomic `field:value` FILTER token grammar → a Mongo filter JS
# object; the `find` / `aggregate` BUILDERS (→ a mongosh JS expression string); the
# canonical Extended JSON DECODER (mongosh `--json=canonical` → real Nushell
# values); schema INFERENCE over sampled docs; and the dangerous-operation guard.
#
# Dialect facts, established by probing `mongosh --nodb` (see plan):
#   - canonical EJSON is REQUIRED: relaxed loses int64 precision beyond 2^53.
#   - canonical wrappers: {$oid}, {$date:{$numberLong:<ms>}}, {$numberInt|$numberLong}
#     (int), {$numberDouble} (float), {$numberDecimal} (kept as string, exact),
#     {$binary:{base64,subType}} (UUID = subType "04"), {$timestamp:{t,i}},
#     {$regularExpression:{pattern,options}}. Numbers are wrapped even when nested,
#     so the decoder must recurse through records and lists.
#
# The BUILDERS emit a JS expression string passed to `mongosh --eval` as a single
# argv (Nushell external calls don't go through a shell — no shell-quoting/injection
# concern), so a builder only needs to emit VALID JS. Date values render as
# `ISODate("…")` (a mongosh helper, valid in --eval), not JSON.

# ---- JS literals ---------------------------------------------------------------

# Render a string as a JS/JSON double-quoted string literal (backslash then quote
# escaped). Field keys are always emitted through this, so dotted/hyphenated keys
# like `address.city` stay valid.
@category mole-mongodb
@example "a plain word" { mongo lit "active" } --result "\"active\""
@example "a dotted key is quoted" { mongo lit "address.city" } --result "\"address.city\""
export def "lit" [v: string]: nothing -> string {
  '"' + ($v | str replace --all '\' '\\' | str replace --all '"' '\"') + '"'
}

# A bare filter-token value → a typed JS literal. Clean integers and floats become
# numeric literals; `true`/`false`/`null` pass through; an ISO-8601 date-shaped
# value becomes `ISODate("…")`; everything else is a quoted string. Conservative
# like VictoriaLogs' `col-kind`: a leading-zero (`007`) or 64-bit-overflowing
# integer is an identifier, so it stays a quoted string (round-trip check).
@category mole-mongodb
@example "an integer" { mongo coerce-scalar "30" } --result "30"
@example "a leading-zero id stays a string" { mongo coerce-scalar "007" } --result "\"007\""
@example "a float" { mongo coerce-scalar "12.5" } --result "12.5"
@example "a boolean" { mongo coerce-scalar "true" } --result "true"
@example "an ISO date" { mongo coerce-scalar "2026-01-02" } --result "ISODate(\"2026-01-02\")"
@example "a word is quoted" { mongo coerce-scalar "admin" } --result "\"admin\""
export def "coerce-scalar" [v: string]: nothing -> string {
  if $v == "null" { return "null" }
  if $v in ["true" "false"] { return $v }
  if ($v =~ '^-?\d+$') and (not ($v =~ '^-?0\d')) {
    # round-trips iff clean: rejects silent i64 overflow (into int saturates)
    if (try { ($v | into int | into string) == $v } catch { false }) { return $v }
  }
  if ($v =~ '^-?(?:\d+\.\d*|\.\d+|\d+[eE][+-]?\d+|\d+\.\d+[eE][+-]?\d+)$') and (not ($v =~ '^-?0\d')) {
    return $v
  }
  if ($v =~ '^\d{4}-\d{2}-\d{2}([Tt].*)?$') { return ("ISODate(" + (lit $v) + ")") }
  lit $v
}

# ---- filter tokens -------------------------------------------------------------

# Comparison-operator spellings → their Mongo query operator.
def cmp-op [s: string]: nothing -> any {
  match $s { ">=" => "$gte", "<=" => "$lte", "!=" => "$ne", ">" => "$gt", "<" => "$lt", _ => null }
}

# One filter token → a Mongo filter JS object fragment. The grammar (mirrors
# VictoriaLogs' `field:value` tokens):
#   {json}          → used verbatim (the raw escape)
#   field           → {"field": true}                    (bare = truthy/exists)
#   field:value     → {"field": <coerced>}               (equality)
#   field:>=value   → {"field": {$gte: <coerced>}}       (> >= < <= !=)
#   field:in:a,b    → {"field": {$in: [<coerced>,…]}}
#   field:~/re/i    → {"field": {$regex: "re", $options: "i"}}
#   field:~pat      → {"field": {$regex: "pat"}}
# The field key is always quoted so dotted paths work. Empty token → "".
@category mole-mongodb
@example "equality" { mongo parse-filter-token "role:admin" } --result "{\"role\": \"admin\"}"
@example "bare field is truthy" { mongo parse-filter-token "active" } --result "{\"active\": true}"
@example "comparison" { mongo parse-filter-token "age:>=30" } --result "{\"age\": {$gte: 30}}"
@example "an in-list" { mongo parse-filter-token "role:in:admin,ops" } --result "{\"role\": {$in: [\"admin\", \"ops\"]}}"
@example "a regex with flags" { mongo parse-filter-token "name:~/^a/i" } --result "{\"name\": {$regex: \"^a\", $options: \"i\"}}"
@example "a raw json token is verbatim" { mongo parse-filter-token "{$expr: {$gt: [\"$a\", \"$b\"]}}" } --result "{$expr: {$gt: [\"$a\", \"$b\"]}}"
export def "parse-filter-token" [tok: string]: nothing -> string {
  let t = ($tok | str trim)
  if ($t | is-empty) { return "" }
  if ($t | str starts-with "{") { return $t }                       # raw escape
  if not ($t | str contains ":") { return ("{" + (lit $t) + ": true}") }
  let idx = ($t | str index-of ":")
  let field = ($t | str substring 0..<$idx)
  let rest = ($t | str substring ($idx + 1)..)
  let key = (lit $field)
  if ($rest | str starts-with "in:") {
    let vals = ($rest | str substring 3.. | split row "," | each {|x| coerce-scalar ($x | str trim) })
    "{" + $key + ": {$in: [" + ($vals | str join ", ") + "]}}"
  } else if ($rest | str starts-with "~") {
    let pat = ($rest | str substring 1..)
    let m = ($pat | parse --regex '^/(?<p>.*)/(?<o>[a-zA-Z]*)$')
    if ($m | is-not-empty) {
      let g = ($m | first)
      "{" + $key + ": {$regex: " + (lit $g.p) + ", $options: " + (lit $g.o) + "}}"
    } else {
      "{" + $key + ": {$regex: " + (lit $pat) + "}}"
    }
  } else {
    let op2 = ($rest | str substring 0..<2)
    let op1 = ($rest | str substring 0..<1)
    let op = if (cmp-op $op2) != null { $op2 } else if (cmp-op $op1) != null { $op1 } else { null }
    if $op != null {
      let val = (coerce-scalar ($rest | str substring ($op | str length).. | str trim))
      "{" + $key + ": {" + (cmp-op $op) + ": " + $val + "}}"
    } else {
      "{" + $key + ": " + (coerce-scalar $rest) + "}"
    }
  }
}

# AND-join filter tokens into one Mongo filter JS object. No tokens → `{}` (match
# all); one token → that object; many → `{$and: [ … ]}` (always correct, including
# two constraints on the same field). Empty/blank tokens are dropped.
@category mole-mongodb
@example "no tokens match everything" { mongo build-filter [] } --result "{}"
@example "a single token" { mongo build-filter ["role:admin"] } --result "{\"role\": \"admin\"}"
@example "many tokens are AND-joined" {
  mongo build-filter ["role:admin" "age:>=30"]
} --result "{$and: [{\"role\": \"admin\"}, {\"age\": {$gte: 30}}]}"
export def "build-filter" [tokens: list<string>]: nothing -> string {
  let frags = ($tokens | each {|t| parse-filter-token $t } | where {|f| $f | is-not-empty })
  if ($frags | is-empty) { "{}" } else if (($frags | length) == 1) { $frags | first } else {
    "{$and: [" + ($frags | str join ", ") + "]}"
  }
}

# ---- find projection / sort ----------------------------------------------------

# A `find` projection object from included / excluded field lists, or null when
# both are empty (omit the projection argument). Includes add `"_id": 0` unless
# `_id` is explicitly projected; excludes are a plain `{f: 0, …}`. (Mongo forbids
# mixing include and exclude except for `_id`; the wrapper passes only one.)
@category mole-mongodb
@example "include projects those fields, dropping _id" {
  mongo projection-spec [name email] []
} --result "{\"name\": 1, \"email\": 1, \"_id\": 0}"
@example "exclude" { mongo projection-spec [] [_stream_id bytes] } --result "{\"_stream_id\": 0, \"bytes\": 0}"
@example "neither → null" { mongo projection-spec [] [] } --result null
export def "projection-spec" [fields: list<string>, exclude: list<string>]: nothing -> any {
  if ($fields | is-not-empty) {
    let incl = ($fields | each {|f| (lit $f) + ": 1" })
    let incl = if ("_id" in $fields) { $incl } else { $incl ++ [((lit "_id") + ": 0")] }
    "{" + ($incl | str join ", ") + "}"
  } else if ($exclude | is-not-empty) {
    "{" + ($exclude | each {|f| (lit $f) + ": 0" } | str join ", ") + "}"
  } else { null }
}

# A `sort` object from comma/space `"field [asc|desc]"` terms, or null when empty.
# Ascending (1) unless the term ends in `desc` → -1.
@category mole-mongodb
@example "ascending by default" { mongo sort-spec ["age"] } --result "{\"age\": 1}"
@example "descending, multi-key" {
  mongo sort-spec ["age desc" "name"]
} --result "{\"age\": -1, \"name\": 1}"
@example "empty → null" { mongo sort-spec [] } --result null
export def "sort-spec" [terms: list<string>]: nothing -> any {
  if ($terms | is-empty) { return null }
  let pairs = ($terms | where {|t| $t | is-not-empty } | each {|term|
    let toks = ($term | str trim | split row --regex '\s+')
    let field = ($toks | first)
    let dir = if (($toks | length) > 1) and (($toks | last | str lowercase) == "desc") { "-1" } else { "1" }
    (lit $field) + ": " + $dir
  })
  if ($pairs | is-empty) { null } else { "{" + ($pairs | str join ", ") + "}" }
}

# Build a `find` mongosh expression: `db.getCollection("coll").find(filter[,proj])`
# with optional `.sort(...).skip(n).limit(n)`, closed by `.toArray()`. `getCollection`
# (not `db.coll`) so collection names with dots/hyphens are safe. Clauses are added
# only when present, so the result is always valid JS.
@category mole-mongodb
@example "just a filter" {
  mongo build-find "users" "{}"
} --result "db.getCollection(\"users\").find({}).toArray()"
@example "projection, sort, limit compose in order" {
  mongo build-find "users" "{\"age\": {$gte: 30}}" --project "{\"name\": 1, \"_id\": 0}" --sort "{\"age\": -1}" --limit 5
} --result "db.getCollection(\"users\").find({\"age\": {$gte: 30}}, {\"name\": 1, \"_id\": 0}).sort({\"age\": -1}).limit(5).toArray()"
export def "build-find" [
  coll: string
  filter: string
  --project: any = null
  --sort: any = null
  --limit: int
  --skip: int
]: nothing -> string {
  let args = if ($project | is-not-empty) { $filter + ", " + $project } else { $filter }
  mut e = "db.getCollection(" + (lit $coll) + ").find(" + $args + ")"
  if ($sort | is-not-empty) { $e = $e + ".sort(" + $sort + ")" }
  if ($skip != null) { $e = $e + ".skip(" + ($skip | into string) + ")" }
  if ($limit != null) { $e = $e + ".limit(" + ($limit | into string) + ")" }
  $e + ".toArray()"
}

# ---- completion helper ---------------------------------------------------------

# Read a flag's value out of a completion-context command line (the same helper
# mole-sql exposes): tries each spelling, accepts `--flag value` / `--flag=value`,
# last wins, null when absent. mod.nu's completers use it to recover the
# `--connection` / `--collection` already typed.
@category mole-mongodb
@example "read a flag" { mongo parse-flag "find -C orders --limit 5" ["--collection" "-C"] } --result "orders"
@example "null when absent" { mongo parse-flag "find" ["--collection" "-C"] } --result null
export def "parse-flag" [ctx: string, names: list<string>]: nothing -> any {
  let pat = '(?:' + ($names | str join "|") + ')[\s=]+(?P<v>[^\s]+)'
  let m = ($ctx | parse --regex $pat)
  if ($m | is-empty) { null } else { $m | last | get v }
}

# ---- safety --------------------------------------------------------------------

# The dangerous-operation regex: write/DDL mongosh methods and the pipeline write
# stages `$out`/`$merge`. Case-insensitive. `mod.nu` passes it to `is-dangerous`.
@category mole-mongodb
export def "mongo-danger" []: nothing -> string {
  '(?i)\.(insertone|insertmany|updateone|updatemany|replaceone|deleteone|deletemany|remove|save|bulkwrite|findandmodify|findoneandupdate|findoneandreplace|findoneanddelete|drop|dropdatabase|createindex|createindexes|dropindex|dropindexes|createcollection|renamecollection)\b|\$out\b|\$merge\b'
}

# Does a mongosh JS statement match the dangerous-operation regex? JS string and
# template/regex-literal spans are blanked FIRST, so a keyword appearing only
# inside a string value (e.g. a field equal to "drop") can't trip the check — only
# real code positions count. Mirrors mole-sql's `is-dangerous`.
@category mole-mongodb
@example "a write is flagged" { mongo is-dangerous "db.users.deleteMany({})" (mongo mongo-danger) } --result true
@example "a plain read is not" { mongo is-dangerous "db.users.find({})" (mongo mongo-danger) } --result false
@example "a keyword inside a string value does not count" {
  mongo is-dangerous "db.users.find({action: \"drop\"})" (mongo mongo-danger)
} --result false
export def "is-dangerous" [js: string, pattern: string]: nothing -> bool {
  let bare = ($js
    | str replace --all --regex '"(?:[^"\\]|\\.)*"' ' '
    | str replace --all --regex "'(?:[^'\\\\]|\\\\.)*'" ' '
    | str replace --all --regex '`[^`]*`' ' ')
  $bare =~ $pattern
}

# ---- aggregate building --------------------------------------------------------
# The aggregation sibling of the find builder. Composes a `$match → $unwind →
# $group → $project → $match(having) → $sort → $skip/$limit` pipeline. The trailing
# `$project` lifts each group key out of `_id` to a TOP-LEVEL column and keeps each
# accumulator alias, so results are flat SQL-`GROUP BY` rows (`{customer, count,
# sum_amount}`) and `--having`/`--sort-by` act on result columns directly. Anything
# not expressible here (top/bottomN with a sort spec, `$accumulator`, window
# functions) is a documented `raw-aggregate` job.

# Sanitize a field into a valid result-alias suffix: any non-word char (notably the
# `.` in dotted paths) → `_`. Mirrors VictoriaLogs' `stat-alias`.
@category mole-mongodb
@example "a plain field is unchanged" { mongo stat-alias "latency" } --result "latency"
@example "a dotted path collapses" { mongo stat-alias "meta.latency" } --result "meta_latency"
export def "stat-alias" [field: string]: nothing -> string {
  $field | str replace --all --regex '[^\w]' '_'
}

# The JS `$group` accumulator expression for one function over a field. `count` is
# `{$sum: 1}` (universal); the field accumulators are `{$fn: "$field"}`; the N-arg
# ones are `{$fn: {input, n}}`; `percentile`/`median` are `{$fn: {input, p?, method}}`.
# An unknown function errors, pointing at `raw-aggregate`.
def acc-js [fn: string, field: any, param: any]: nothing -> string {
  let fref = if ($field | is-not-empty) { lit ("$" + $field) } else { null }
  let need_field = {|| if ($fref == null) { error make {msg: $"aggregation '($fn)' needs a field: ($fn):<field>"} } }
  match $fn {
    "count" => "{$sum: 1}"
    "sum" | "avg" | "min" | "max" | "first" | "last" | "push" | "addToSet" | "stdDevPop" | "stdDevSamp" | "mergeObjects" => {
      do $need_field
      "{$" + $fn + ": " + $fref + "}"
    }
    "firstN" | "lastN" | "minN" | "maxN" => {
      do $need_field
      if ($param | is-empty) { error make {msg: $"aggregation '($fn)' needs N: ($fn):<field>:<N>"} }
      "{$" + $fn + ": {input: " + $fref + ", n: " + ($param | into string) + "}}"
    }
    "percentile" => {
      do $need_field
      if ($param | is-empty) { error make {msg: "percentile needs p: percentile:<field>:<p> (e.g. 0.95)"} }
      "{$percentile: {input: " + $fref + ", p: [" + ($param | into string) + "], method: \"approximate\"}}"
    }
    "median" => {
      do $need_field
      "{$median: {input: " + $fref + ", method: \"approximate\"}}"
    }
    _ => { error make {msg: $"unknown aggregation '($fn)' — use raw-aggregate for top/bottomN, \\$accumulator, or window functions"} }
  }
}

# Parse one `fn:field[:param][=alias]` accumulator token into `{alias, accumulator}`.
# The default alias is `count` for count, else `<fn>_<sanitized-field>`; `=alias`
# overrides it.
@category mole-mongodb
@example "a bare count" { mongo parse-agg-token "count" } --result {alias: count, accumulator: "{$sum: 1}"}
@example "sum over a field" { mongo parse-agg-token "sum:amount" } --result {alias: sum_amount, accumulator: "{$sum: \"$amount\"}"}
@example "percentile with param and explicit alias" {
  mongo parse-agg-token "percentile:latency:0.95=p95"
} --result {alias: p95, accumulator: "{$percentile: {input: \"$latency\", p: [0.95], method: \"approximate\"}}"}
export def "parse-agg-token" [tok: string]: nothing -> record {
  let t = ($tok | str trim)
  let eq = ($t | str index-of "=")
  let body = if $eq >= 0 { $t | str substring 0..<$eq } else { $t }
  let alias_override = if $eq >= 0 { $t | str substring ($eq + 1).. } else { null }
  let parts = ($body | split row ":")
  let fn = ($parts | first)
  let field = ($parts | get -o 1)
  let param = ($parts | get -o 2)
  let alias = if ($alias_override | is-not-empty) { $alias_override
  } else if $fn == "count" { "count"
  } else { $fn + "_" + (stat-alias ($field | default "")) }
  {alias: $alias, accumulator: (acc-js $fn $field $param)}
}

# The `$group` `_id` spec from group-by fields plus an optional `field:unit` date
# bucket, and the flat list of key names it introduces. No keys → `_id: null`
# (group everything). A date bucket renders `{$dateTrunc: {date, unit}}`.
def id-spec [by: list<string>, date_bucket: any]: nothing -> record {
  mut pairs = []
  mut keys = []
  for k in ($by | where {|x| $x | is-not-empty }) {
    $pairs = ($pairs | append ((lit $k) + ": " + (lit ("$" + $k))))
    $keys = ($keys | append $k)
  }
  if ($date_bucket | is-not-empty) {
    let dp = ($date_bucket | split row ":")
    let dfield = ($dp | first)
    let unit = ($dp | get -o 1 | default "day")
    $pairs = ($pairs | append ((lit $dfield) + ": {$dateTrunc: {date: " + (lit ("$" + $dfield)) + ", unit: " + (lit $unit) + "}}"))
    $keys = ($keys | append $dfield)
  }
  {js: (if ($pairs | is-empty) { "null" } else { "{" + ($pairs | str join ", ") + "}" }), keys: $keys}
}

# Build an `aggregate` mongosh expression from structured parts. Every clause is
# added only when present, so the pipeline is always valid. Group keys are lifted
# to top-level by the trailing `$project` (flat wide rows).
@category mole-mongodb
@example "a bare grouped count" {
  mongo build-pipeline "orders" --by [customer] --agg ["count"]
} --result "db.getCollection(\"orders\").aggregate([{$group: {_id: {\"customer\": \"$customer\"}, \"count\": {$sum: 1}}}, {$project: {\"_id\": 0, \"customer\": \"$_id.customer\", \"count\": 1}}]).toArray()"
@example "filter, multi-aggregation, having, sort, limit" {
  mongo build-pipeline "orders" --match "{\"active\": true}" --by [customer] --agg ["count" "sum:amount"] --having "{\"sum_amount\": {$gte: 1000}}" --sort "{\"sum_amount\": -1}" --limit 10
} --result "db.getCollection(\"orders\").aggregate([{$match: {\"active\": true}}, {$group: {_id: {\"customer\": \"$customer\"}, \"count\": {$sum: 1}, \"sum_amount\": {$sum: \"$amount\"}}}, {$project: {\"_id\": 0, \"customer\": \"$_id.customer\", \"count\": 1, \"sum_amount\": 1}}, {$match: {\"sum_amount\": {$gte: 1000}}}, {$sort: {\"sum_amount\": -1}}, {$limit: 10}]).toArray()"
export def "build-pipeline" [
  coll: string
  --match: string = "{}"          # pre-group filter (from build-filter); "{}" drops the stage
  --unwind: any = null            # field to $unwind
  --by: list<string> = []         # $group key fields
  --date-bucket: any = null       # "field:unit" → a $dateTrunc group key
  --agg: list<string> = []        # fn:field:param=alias accumulator tokens
  --having: string = "{}"         # post-group filter over result columns; "{}" drops the stage
  --sort: any = null              # $sort over result columns (from sort-spec)
  --limit: int
  --skip: int
]: nothing -> string {
  let id = (id-spec $by $date_bucket)
  let accs = ($agg | where {|a| $a | is-not-empty } | each {|a| parse-agg-token $a })
  let accjs = ($accs | each {|a| (lit $a.alias) + ": " + $a.accumulator })
  let groupdoc = "{_id: " + $id.js + (if ($accjs | is-empty) { "" } else { ", " + ($accjs | str join ", ") }) + "}"
  let projpairs = (["\"_id\": 0"]
    ++ ($id.keys | each {|k| (lit $k) + ": " + (lit ("$_id." + $k)) })
    ++ ($accs | each {|a| (lit $a.alias) + ": 1" }))
  mut stages = []
  if $match != "{}" { $stages = ($stages | append ("{$match: " + $match + "}")) }
  if ($unwind | is-not-empty) { $stages = ($stages | append ("{$unwind: " + (lit ("$" + $unwind)) + "}")) }
  $stages = ($stages | append ("{$group: " + $groupdoc + "}"))
  $stages = ($stages | append ("{$project: {" + ($projpairs | str join ", ") + "}}"))
  if $having != "{}" { $stages = ($stages | append ("{$match: " + $having + "}")) }
  if ($sort | is-not-empty) { $stages = ($stages | append ("{$sort: " + $sort + "}")) }
  if ($skip != null) { $stages = ($stages | append ("{$skip: " + ($skip | into string) + "}")) }
  if ($limit != null) { $stages = ($stages | append ("{$limit: " + ($limit | into string) + "}")) }
  "db.getCollection(" + (lit $coll) + ").aggregate([" + ($stages | str join ", ") + "]).toArray()"
}

# ---- Extended JSON decode ------------------------------------------------------
# mongosh `--json=canonical` output, parsed with `from json`, arrives with every
# BSON value wrapped in a single-key `$`-tagged record (and numbers wrapped even
# when nested). `ejson-decode` walks the structure and turns those wrappers into
# real Nushell values, recursing through documents and arrays. A field name can't
# begin with `$` in MongoDB, so a `$`-tag is never a genuine user key — the
# detection is unambiguous. This is the whole "typed results" story; `--raw` skips
# it and returns the wrappers untouched.

# A `$numberDouble` string → float; the non-finite spellings → null (Nushell has
# no inf/NaN literal), matching VictoriaLogs' `num`.
def decode-double [s: any]: nothing -> any {
  if ($s | describe) != "string" { return $s }
  if $s in ["Infinity" "-Infinity" "NaN"] { return null }
  try { $s | into float } catch { $s }
}

# A `$date` value → datetime. Canonical form is `{$numberLong: "<ms-since-epoch>"}`
# (millisecond precision, exact via i64); relaxed form is an ISO-8601 string.
def decode-date [d: any]: nothing -> any {
  if (($d | describe) | str starts-with "record") {
    let ms = ($d | get -o "$numberLong" | default "0" | into int)
    return (1970-01-01T00:00:00Z + ($ms * 1ms))
  }
  try { $d | into datetime } catch { $d }
}

# Recursively decode a canonical-Extended-JSON value into native Nushell values:
#   {$oid}→string  {$numberInt|$numberLong}→int  {$numberDouble}→float
#   {$numberDecimal}→string (exact)  {$date}→datetime  {$regularExpression}→"/pat/opts"
#   {$binary}→{base64,subType}  {$timestamp}→{t,i}  {$uuid}→string
#   {$minKey}/{$maxKey}→"MinKey"/"MaxKey"  {$undefined}→null
# a plain document → a record with each field decoded; an array → a list of decoded
# elements; anything else passes through.
@category mole-mongodb
@example "an ObjectId becomes its hex string" {
  mongo ejson-decode {"$oid": "64b7f0f0f0f0f0f0f0f0f0f0"}
} --result "64b7f0f0f0f0f0f0f0f0f0f0"
@example "a canonical date becomes a datetime" {
  mongo ejson-decode {"$date": {"$numberLong": "1767323045678"}}
} --result 2026-01-02T03:04:05.678Z
@example "int64 keeps full precision" {
  mongo ejson-decode {"$numberLong": "9007199254740993"}
} --result 9007199254740993
@example "a nested document is decoded field by field" {
  mongo ejson-decode {a: {"$numberInt": "1"}, b: [{"$numberInt": "2"}, {"$numberInt": "3"}]}
} --result {a: 1, b: [2, 3]}
export def "ejson-decode" [v: any]: nothing -> any {
  let t = ($v | describe)
  if ($t | str starts-with "record") {
    let cols = ($v | columns)
    if ("$oid" in $cols) { return ($v | get "$oid") }
    if ("$numberInt" in $cols) { return ($v | get "$numberInt" | into int) }
    if ("$numberLong" in $cols) { return ($v | get "$numberLong" | into int) }
    if ("$numberDouble" in $cols) { return (decode-double ($v | get "$numberDouble")) }
    if ("$numberDecimal" in $cols) { return ($v | get "$numberDecimal") }
    if ("$date" in $cols) { return (decode-date ($v | get "$date")) }
    if ("$regularExpression" in $cols) {
      let r = ($v | get "$regularExpression")
      return ("/" + ($r | get -o pattern | default "") + "/" + ($r | get -o options | default ""))
    }
    if ("$binary" in $cols) { return ($v | get "$binary") }        # {base64, subType}
    if ("$timestamp" in $cols) { return ($v | get "$timestamp") }  # {t, i}
    if ("$uuid" in $cols) { return ($v | get "$uuid") }
    if ("$minKey" in $cols) { return "MinKey" }
    if ("$maxKey" in $cols) { return "MaxKey" }
    if ("$undefined" in $cols) { return null }
    if ("$code" in $cols) { return ($v | get "$code") }
    return ($v | items {|k, val| {k: $k, v: (ejson-decode $val)} } | reduce --fold {} {|it, acc| $acc | upsert $it.k $it.v })
  }
  if ($t | str starts-with "list") or ($t | str starts-with "table") {
    return ($v | each {|e| ejson-decode $e })
  }
  $v
}

# ---- schema inference (over sampled, already-decoded docs) ---------------------
# MongoDB is schemaless, so the completion catalog and the `schema` verb infer
# structure by SAMPLING documents. Unlike VictoriaLogs' string inference (one
# collapsed type per column), this observes ALREADY-DECODED values and reports a
# type SET per field — a field may legitimately hold different BSON types across
# documents, and collapsing that would be a lie. Nested documents and
# arrays-of-subdocuments are flattened to dotted paths (`address.city`,
# `items.sku`) so projection/filter/sort completion reaches them.

# The simple type name of a value: `describe` with any generic parameters stripped
# (`record<…>`→`record`, `int`→`int`). A homogeneous list of records describes as
# `table`; both `table` and `list` normalize to `list`, so an array field reads
# uniformly regardless of whether its elements happen to be homogeneous records.
def simple-type [v: any]: nothing -> string {
  let d = ($v | describe | split row '<' | first)
  if $d == "table" { "list" } else { $d }
}

# Observe a column of decoded values → its distinct non-null type set (sorted) and
# whether any value was null.
@category mole-mongodb
@example "a homogeneous column" { mongo observe [1 2 3] } --result {types: [int], nullable: false}
@example "a mixed column reports every type" { mongo observe [1 "a"] } --result {types: [int, string], nullable: false}
@example "nulls set nullable" { mongo observe [1 null] } --result {types: [int], nullable: true}
export def "observe" [vals: list]: nothing -> record {
  let types = ($vals | where {|v| $v != null } | each {|v| simple-type $v } | uniq | sort)
  {types: $types, nullable: ($vals | any {|v| $v == null })}
}

# Every dotted leaf/container path reachable under one decoded value, as
# `{path, value}` rows. A record descends field-by-field (emitting both the
# container and its children); an array descends into RECORD elements under the
# same path (so array-of-subdoc fields appear), aggregating across elements.
def child-paths [v: any, prefix: string]: nothing -> list {
  let t = ($v | describe)
  if ($t | str starts-with "record") {
    $v | items {|k, vv| ([{path: ($prefix + "." + $k), value: $vv}] ++ (child-paths $vv ($prefix + "." + $k))) } | flatten
  } else if ($t | str starts-with "list") or ($t | str starts-with "table") {
    $v | each {|el|
      if (($el | describe) | str starts-with "record") {
        $el | items {|k, vv| ([{path: ($prefix + "." + $k), value: $vv}] ++ (child-paths $vv ($prefix + "." + $k))) } | flatten
      } else { [] }
    } | flatten
  } else { [] }
}

# Infer a collection's schema from sampled, decoded documents. Returns one row per
# discovered field path — `{name, types, nullable, occurrence}` — where `types` is
# the observed type set, `nullable` is true if any doc had it null or missing, and
# `occurrence` is the percentage of sampled docs that carry the path. Sorted by
# name. Powers `schema` and the field completers.
@category mole-mongodb
@example "a field present in some docs is partial and typed by its values" {
  mongo infer-schema [{name: "a", age: 30} {name: "b"}]
} --result [{name: age, types: [int], nullable: true, occurrence: 50}, {name: name, types: [string], nullable: false, occurrence: 100}]
@example "nested docs and arrays-of-subdocs flatten to dotted paths" {
  mongo infer-schema [{addr: {city: "x"}, items: [{sku: "a"} {sku: "b"}]}] | get name
} --result [addr, addr.city, items, items.sku]
export def "infer-schema" [docs: list]: nothing -> list {
  let total = ($docs | length)
  if $total == 0 { return [] }
  let per_doc = ($docs | where {|d| ($d | describe) | str starts-with "record" } | each {|d|
    $d | items {|k, v| ([{path: $k, value: $v}] ++ (child-paths $v $k)) } | flatten
  })
  let all_entries = ($per_doc | flatten)
  if ($all_entries | is-empty) { return [] }
  let counts = ($per_doc | each {|entries| $entries | get path | uniq } | flatten | uniq --count)
  $all_entries | group-by path | items {|path, rows|
    let ob = (observe ($rows | get value))
    let docs = ($counts | where value == $path | get -o 0.count | default 0)
    {
      name: $path
      types: $ob.types
      nullable: (($ob.nullable) or ($docs < $total))
      occurrence: (((($docs * 100) / $total)) | math round)
    }
  } | sort-by name
}
