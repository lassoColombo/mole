# mole-mongodb — MongoDB driver plugin (mongosh-backed).
#
# A PLUGIN (data source): supports the `mongodb` driver, registers itself, and
# exposes a read-oriented, fully-completing surface — `find` / `aggregate` /
# `distinct` / `count` / `collections` / `schema` / `indexes` — plus danger-gated
# raw escape hatches `raw-query` / `raw-aggregate` and `set-connection`. It drives
# the `mongosh` CLI, asking for CANONICAL Extended JSON (`--json=canonical`) so
# BSON types survive losslessly (relaxed EJSON corrupts int64 > 2^53). It registers
# the `mongodb` driver at load via `conn register` (no manifest).
#
# LAYERING (mirrors mole-victorialogs' split):
#   - mongo.nu — PURE builders/decoder/inference/danger (imported privately). Owns
#     the JS query strings, the EJSON→typed-value decode, and schema inference.
#   - mod.nu   — THIS wrapper. Owns policy: connection→mongosh invocation, the
#     completion catalog (sampled schema, cached a day), turning payloads into typed
#     rows, and the completion catalog. Read-oriented is structural; only the two
#     raw verbs can carry writes, so only they are danger-gated.
#
# All completers scope to the `--collection`/`--connection` already on the command
# line (via `mongo parse-flag`); `aggregate`'s `--having`/`--sort-by` even complete
# the RESULT columns derived from the sibling `--by`/`--agg` — completion is
# contextual to the other arguments.

use mole/lib/conn.nu

# Driver-scoped connection completer: only THIS driver (mongodb), never other drivers.
def "complete-connection" []: nothing -> list<string> { conn names "mongodb" }
use mole/lib/cache.nu
use mole/lib/query.nu
use mole/lib/complete.nu
use ./mongo.nu

export-env {
  conn register "mongodb"
}

# ---- connection resolution -----------------------------------------------------

# Resolve a mongodb connection (named, or the current one) and apply ad-hoc
# overrides. Null overrides are dropped (see `conn override`). Asserts the
# connection is a mongodb one (via `conn with` → `conn resolve --driver`).
def mongo-conf [
  connection: any, host: any, port: any, user: any, password: any,
  database: any, auth_source: any, uri: any, set: record
]: nothing -> record {
  conn with mongodb $connection ({
    host: $host, port: $port, user: $user, password: $password,
    database: $database, "auth-source": $auth_source, uri: $uri
  } | merge $set)
}

# The mongodb:// connection string for a resolved connection. A raw `uri` field
# wins verbatim; otherwise build `mongodb://host:port/db`. Credentials are passed
# as mongosh flags (see mongo-exec), NOT embedded here, to avoid URI-escaping.
def mongo-uri [conf: record]: nothing -> string {
  let raw = ($conf | get -o uri)
  if ($raw | is-not-empty) { return $raw }
  let host = ($conf | get -o host | default "localhost")
  let port = ($conf | get -o port | default 27017)
  let db = ($conf | get -o database | default "")
  $"mongodb://($host):($port)/($db)"
}

# Run one mongosh eval and return its parsed (NOT yet decoded) canonical-EJSON
# result. Credentials/tls ride as flags. `--fast` bounds server selection so a
# dead server fails a completer quickly instead of hanging. Non-zero exit raises
# via `query check` (mongosh writes the error to stderr).
def mongo-exec [conf: record, js: string, --fast]: nothing -> any {
  let base = (mongo-uri $conf)
  let uri = if $fast { $base + (if ($base | str contains "?") { "&" } else { "?" }) + "serverSelectionTimeoutMS=2000" } else { $base }
  mut args = [$uri "--quiet" "--json=canonical"]
  let user = ($conf | get -o user)
  if ($user | is-not-empty) {
    $args = ($args ++ ["--username" $user "--password" ($conf | get -o password | default "") "--authenticationDatabase" ($conf | get -o "auth-source" | default "admin")])
  }
  if (($conf | get -o tls | default false) == true) { $args = ($args ++ ["--tls"]) }
  (^mongosh ...$args --eval $js | complete | query check) | from json
}

# Exec + decode: the typed-rows path. `raw` returns the parsed EJSON wrappers
# untouched (lossless); otherwise `ejson-decode` turns them into native values.
def mongo-run [conf: record, js: string, raw: bool]: nothing -> any {
  let parsed = (mongo-exec $conf $js)
  if $raw { $parsed } else { mongo ejson-decode $parsed }
}

# ---- completion catalog --------------------------------------------------------

# The single mongosh program that gathers the catalog in one round-trip: database
# names, non-system collections (name/type/count/indexes) and a $sample of docs per
# collection (a plain find for views, which can't $sample). `__SAMPLE__` is filled
# by mongo-catalog-load.
def mongo-catalog-js [sample: int]: nothing -> string {
  let tmpl = r#'(function(){
  const dbs = db.getMongo().getDBNames();
  const infos = db.getCollectionInfos().filter(c => !c.name.startsWith("system."));
  const colls = infos.map(function(c){
    const coll = db.getCollection(c.name);
    let count = 0;
    try { count = coll.estimatedDocumentCount(); } catch(e) { try { count = coll.countDocuments({}); } catch(e2) {} }
    let indexes = [];
    try { indexes = coll.getIndexes(); } catch(e) {}
    let sample = [];
    try {
      sample = (c.type === "view")
        ? coll.find().limit(__SAMPLE__).toArray()
        : coll.aggregate([{$sample: {size: __SAMPLE__}}]).toArray();
    } catch(e) {}
    return {name: c.name, type: c.type, count: count, indexes: indexes, sample: sample};
  });
  return {databases: dbs, collections: colls};
})()'#
  $tmpl | str replace --all "__SAMPLE__" ($sample | into string)
}

# Cache-file path for a connection's catalog (namespaced by connection + database).
def mongo-cache-file [conf: record]: nothing -> string {
  let db = ($conf | get -o database | default "_")
  cache path "mongodb" $"(($conf | get -o name) | default '_')__($db)"
}

# Load the completion/schema catalog for a connection, rebuilding when --refresh or
# stale (1 day). Samples `--sample` docs per collection and infers each collection's
# field paths + type sets. System databases (admin/config/local) are dropped.
def mongo-catalog-load [conf: record, --refresh, --sample: int = 100]: nothing -> record {
  let file = (mongo-cache-file $conf)
  if (not $refresh) and (not (cache stale $file 1day)) { return (cache read $file) }
  let decoded = (mongo ejson-decode (mongo-exec $conf (mongo-catalog-js $sample)))
  let dbs = ($decoded | get -o databases | default [] | where {|d| $d not-in ["admin" "config" "local"] })
  let colls = ($decoded | get -o collections | default [])
  let fields = ($colls | each {|c|
    (mongo infer-schema ($c | get -o sample | default [])) | each {|f| {collection: $c.name} | merge $f }
  } | flatten)
  let collmeta = ($colls | each {|c| {name: $c.name, type: $c.type, count: ($c | get -o count | default 0), indexes: ($c | get -o indexes | default [])} })
  let data = {
    meta: {connection: ($conf | get -o name), database: ($conf | get -o database | default "_"), driver: "mongodb", refreshed_at: (date now)}
    databases: $dbs
    collections: $collmeta
    fields: $fields
  }
  $data | cache write $file
  $data
}

# Warm the catalog after a successful query, but only when cold (missing).
# Best-effort — the connection is known reachable here, so it never breaks the call.
def mongo-warm [conf: record]: nothing -> nothing {
  if (cache read (mongo-cache-file $conf) | is-not-empty) { return }
  try { mongo-catalog-load $conf | ignore } catch { }
}

# ---- completion helpers --------------------------------------------------------

# The token under the cursor: the last whitespace-delimited chunk of the context.
def mongo-token [ctx: string]: nothing -> string { $ctx | split row " " | last }

# Split a comma-separated flag value into a clean list (trims, drops blanks).
def csv [v: any]: nothing -> list<string> {
  $v | default "" | split row "," | str trim | where {|x| $x | is-not-empty }
}

# The cached catalog for whatever connection/database the command line names (or
# the current). Cache-only — never hits the network, so completers stay instant.
def mongo-cache-ctx [ctx: string]: nothing -> record {
  try {
    let conf = (conn with mongodb (mongo parse-flag $ctx ["--connection" "-c"]) {})
    let db = ((mongo parse-flag $ctx ["--database" "-d"]) | default ($conf | get -o database) | default "_")
    (cache read (cache path "mongodb" $"(($conf | get -o name) | default '_')__($db)")) | default {}
  } catch { {} }
}

# Cached field names for the `--collection` named on the line (all collections'
# fields when none is named). Deduped and sorted.
def mongo-fields-for [ctx: string]: nothing -> list<string> {
  let coll = (mongo parse-flag $ctx ["--collection" "-C"])
  (mongo-cache-ctx $ctx | get -o fields | default [])
  | where {|f| ($coll | is-empty) or ($f.collection == $coll) }
  | get -o name | default [] | uniq | sort
}

# The result columns an `aggregate` produces, derived from the `--by`/`--date-bucket`
# group keys and the `--agg` accumulator aliases ALREADY on the line — so `--having`
# and `--sort-by` complete columns that don't exist until the aggs are typed.
def mongo-result-cols [ctx: string]: nothing -> list<string> {
  let by = (csv (mongo parse-flag $ctx ["--by" "-b"]))
  let dbk = (mongo parse-flag $ctx ["--date-bucket"])
  let bydate = if ($dbk | is-not-empty) { [($dbk | split row ":" | first)] } else { [] }
  let aliases = (csv (mongo parse-flag $ctx ["--agg" "-a"]) | each {|t| try { (mongo parse-agg-token $t).alias } catch { null } } | where {|x| $x != null })
  $by ++ $bydate ++ $aliases
}

# --- the completers (attached to flags/positional via @"name") ---

def "mongo-collection" [ctx: string]: nothing -> list<string> {
  mongo-cache-ctx $ctx | get -o collections | default [] | get -o name | default []
}

def "mongo-field" [ctx: string]: nothing -> list<string> { mongo-fields-for $ctx }

# Comma-list field completer: re-prepends the already-typed values so accepting a
# candidate extends the list (`_id,ho⇥` → `_id,host`). Nushell can't complete inside
# a `[...]` literal, so these flags are comma-separated strings.
def "mongo-fields-csv" [ctx: string]: nothing -> list<string> {
  let prefix = (mongo-token $ctx | str replace --regex '[^,]*$' '')
  mongo-fields-for $ctx | each {|f| $"($prefix)($f)" }
}

# Two-stage filter-token completer, like VictoriaLogs' `vl-filter`. No `:` in the
# token → a `field:` for every cached field (instant, cache-only). `field:…` → a
# LIVE `distinct` on that field (fast-timeout, best-effort, capped) so
# `role:ad⇥` → `role:admin`. The one completer that touches the network.
def "mongo-filter" [ctx: string]: nothing -> list<string> {
  let tok = (mongo-token $ctx)
  if not ($tok | str contains ":") {
    mongo-fields-for $ctx | each {|f| $"($f):" }
  } else {
    try {
      let field = ($tok | split row ":" | first)
      let coll = (mongo parse-flag $ctx ["--collection" "-C"])
      let conf = (conn with mongodb (mongo parse-flag $ctx ["--connection" "-c"]) {})
      let js = "db.getCollection(" + (mongo lit $coll) + ").distinct(" + (mongo lit $field) + ").slice(0, 50)"
      (mongo ejson-decode (mongo-exec $conf $js --fast)) | each {|v| $"($field):($v)" }
    } catch { [] }
  }
}

# Accumulator functions, in the order they are offered. Field-taking ones carry a
# trailing `:`; `count` takes no field.
const AGG_FNS = [count "sum:" "avg:" "min:" "max:" "first:" "last:" "push:" "addToSet:" "stdDevPop:" "stdDevSamp:" "mergeObjects:" "firstN:" "lastN:" "minN:" "maxN:" "percentile:" "median:"]

# Multi-stage `--agg` completer over the last comma segment: function name → field
# → param hint (N for the *N funcs, a percentile like 0.95). Comma-prefix preserved.
def "mongo-agg" [ctx: string]: nothing -> list<string> {
  let raw = (mongo-token $ctx)
  let prefix = ($raw | str replace --regex '[^,]*$' '')
  let seg = ($raw | split row "," | last)
  let colons = ($seg | split row ":" | length) - 1
  if $colons == 0 {
    $AGG_FNS | each {|f| $"($prefix)($f)" }
  } else if $colons == 1 {
    let fn = ($seg | split row ":" | first)
    mongo-fields-for $ctx | each {|f| $"($prefix)($fn):($f)" }
  } else {
    let base = ($seg | split row ":" | first 2 | str join ":")
    let fn = ($seg | split row ":" | first)
    let hints = if $fn == "percentile" { ["0.5" "0.9" "0.95" "0.99"] } else { ["5" "10" "25" "100"] }
    $hints | each {|h| $"($prefix)($base):($h)" }
  }
}

# `--having` completes result-column tokens (`<col>:`), scoped to the sibling
# `--by`/`--agg` (see mongo-result-cols).
def "mongo-having" [ctx: string]: nothing -> list<string> {
  let tok = (mongo-token $ctx)
  if not ($tok | str contains ":") { mongo-result-cols $ctx | each {|c| $"($c):" } } else { [] }
}

# `--sort-by` for aggregate: a comma-list over result columns (keys + agg aliases).
def "mongo-result-sort-csv" [ctx: string]: nothing -> list<string> {
  let prefix = (mongo-token $ctx | str replace --regex '[^,]*$' '')
  mongo-result-cols $ctx | each {|c| $"($prefix)($c)" }
}

def "mongo-database" [ctx: string]: nothing -> list<string> {
  mongo-cache-ctx $ctx | get -o databases | default []
}

# `--date-bucket` = `field:unit`. No `:` → datetime-typed fields as `field:`; after
# the colon → the $dateTrunc units.
def "mongo-datebucket" [ctx: string]: nothing -> list<string> {
  let tok = (mongo-token $ctx)
  if not ($tok | str contains ":") {
    let coll = (mongo parse-flag $ctx ["--collection" "-C"])
    (mongo-cache-ctx $ctx | get -o fields | default [])
    | where {|f| (($coll | is-empty) or ($f.collection == $coll)) and ("datetime" in ($f | get -o types | default [])) }
    | get -o name | default [] | each {|f| $"($f):" }
  } else {
    let field = ($tok | split row ":" | first)
    ["minute" "hour" "day" "week" "month" "quarter" "year"] | each {|u| $"($field):($u)" }
  }
}

# Value-suggestion completers so numeric flags also complete.
def "mongo-int-limit" []: nothing -> list<string> { [10 20 50 100 500 1000] | each {|n| $n | into string } }
def "mongo-int-skip" []: nothing -> list<string> { [0 10 20 50 100] | each {|n| $n | into string } }
def "mongo-int-sample" []: nothing -> list<string> { [50 100 200 500] | each {|n| $n | into string } }

def "mongo-host" [ctx: string]: nothing -> list<string> { conn list | where driver == "mongodb" | get -o host | default [] | uniq }
def "mongo-port" [ctx: string]: nothing -> list<string> { ["27017"] ++ (conn list | where driver == "mongodb" | get -o port | default [] | each {|p| $p | into string }) | uniq }
def "mongo-user" [ctx: string]: nothing -> list<string> { conn list | where driver == "mongodb" | get -o user | default [] | uniq }

# ---- user verbs ----------------------------------------------------------------

# Run an arbitrary mongosh statement against a MongoDB connection.
#
# The JS is the positional <expr>, a saved `--file` (resolved under the query dir
# with a `.mongodb` suffix), or `$EDITOR` when neither is given. End cursor-producing
# statements with `.toArray()` so the result serializes. Rows come back TYPED —
# canonical Extended JSON decoded to native values (ObjectId→string, dates→datetime,
# int64 exact, Decimal128→exact string); `--raw` returns the EJSON wrappers untouched.
# A statement matching the dangerous-op regex (writes/DDL, `$out`/`$merge`) prompts
# first, which `--yes` skips. Named `raw-query` (the raw brother of `find`/`aggregate`).
@category mole-mongodb
@example "an ad-hoc query" { mole-mongodb raw-query 'db.users.find({age: {$gt: 30}}).toArray()' -c mongodb-local-dev }
@example "a saved query piped via stdin" { mole query show reports/active.mongodb | mole-mongodb raw-query -c prod }
export def "raw-query" [
  expr?: string                                   # mongosh JS (else --file, else stdin, else $EDITOR)
  --file(-f): string@"complete queryfile"         # saved query file (relative to the query dir)
  --connection(-c): string@"complete-connection"  # named connection (default: current)
  --host(-h): string@"mongo-host"
  --port(-p): int@"mongo-port"
  --user(-u): string@"mongo-user"
  --password(-P): string
  --database(-d): string@"mongo-database"
  --auth-source: string
  --uri: string
  --set: record = {}
  --raw(-R)                                        # raw EJSON wrappers: skip decode
  --yes(-y)                                        # skip the dangerous-op prompt
] {
  let conf = (mongo-conf $connection $host $port $user $password $database $auth_source $uri $set)
  let js = ($in | query resolve $expr --file $file --suffix ".mongodb")
  if (mongo is-dangerous $js (mongo mongo-danger)) and (not (query confirm "This may modify data. Run it?" --yes=$yes)) { return }
  let rows = (mongo-run $conf $js $raw)
  mongo-warm $conf
  $rows
}

# Compose and run a MongoDB `find`, returning typed documents.
#
# The autocompleting mirror of `raw-query`. `...filters` are `field:value` tokens
# (`active`, `role:admin`, `age:>=30`, `name:~/^a/i`, `role:in:a,b`), AND-joined; a
# raw `{…}` JSON token is the escape. `--select`/`--exclude` project fields (comma-
# lists, completing), `--sort-by` orders (`"field [asc|desc]"`, comma-list),
# `--limit`/`--skip` paginate. Rows are typed like `raw-query` (`--raw` keeps the
# wrappers). `--dry-run` returns `{connection, query}` — the resolved connection
# (secrets dropped) and the composed JS — without running it.
@category mole-mongodb
@example "filter, project, order, limit" {
  mole-mongodb find role:admin age:>=30 -C users --select name,email --sort-by "age desc" --limit 5 -c mongodb-local-dev
}
@example "a regex filter and an in-list" {
  mole-mongodb find 'name:~/^a/i' status:in:paid,pending -C orders -c mongodb-local-dev
}
export def "find" [
  ...filters: string@"mongo-filter"               # field:value filter tokens (AND-joined)
  --collection(-C): string@"mongo-collection"     # target collection (required)
  --select(-S): string@"mongo-fields-csv"         # projected fields, comma-separated
  --exclude(-x): string@"mongo-fields-csv"        # excluded fields, comma-separated
  --sort-by(-s): string@"mongo-fields-csv"        # sort fields: "field [asc|desc]", comma-separated
  --limit(-l): int@"mongo-int-limit"
  --skip(-k): int@"mongo-int-skip"
  --connection(-c): string@"complete-connection"
  --host(-h): string@"mongo-host"
  --port(-p): int@"mongo-port"
  --user(-u): string@"mongo-user"
  --password(-P): string
  --database(-d): string@"mongo-database"
  --auth-source: string
  --uri: string
  --set: record = {}
  --raw(-R)
  --dry-run(-n)
] {
  if ($collection | is-empty) { error make {msg: "find: --collection <name> is required"} }
  let conf = (mongo-conf $connection $host $port $user $password $database $auth_source $uri $set)
  let filter = (mongo build-filter $filters)
  let proj = (mongo projection-spec (csv $select) (csv $exclude))
  let sort = (mongo sort-spec (csv $sort_by))
  let js = (mongo build-find $collection $filter --project $proj --sort $sort --limit $limit --skip $skip)
  if $dry_run { return {connection: ($conf | conn redact), query: $js} }
  let rows = (mongo-run $conf $js $raw)
  mongo-warm $conf
  $rows
}

# Compose and run an aggregation, returning flat SQL-`GROUP BY`-shaped rows.
#
# `...match` are `find`-style filter tokens for the `$match` stage. `--by` are group
# keys (comma-list); `--date-bucket field:unit` groups a datetime into buckets.
# `--agg` is a comma-list of `fn:field[:param][=alias]` accumulators — count, sum,
# avg, min, max, first, last, push, addToSet, stdDevPop, stdDevSamp, mergeObjects,
# firstN/lastN/minN/maxN (param N), percentile (param p), median. `--having` filters
# result columns (post-group), `--sort-by`/`--limit`/`--skip` order and paginate over
# them. Group keys are lifted to top-level columns (keys first), so results read like
# a GROUP BY. `--raw` keeps EJSON wrappers; `--dry-run` returns `{connection, query}`.
# For top/bottomN with a sort spec, `$accumulator`, or window functions, use
# `raw-aggregate`.
@category mole-mongodb
@example "count and revenue per customer, biggest first" {
  mole-mongodb aggregate active -C orders --by customer --agg count,sum:amount --sort-by "sum_amount desc" --limit 10 -c mongodb-local-dev
}
@example "hourly event counts (date bucket)" {
  mole-mongodb aggregate -C events --date-bucket created:hour --agg count -c mongodb-local-dev
}
@example "95th-percentile latency per route, only busy routes" {
  mole-mongodb aggregate -C requests --by route --agg count,percentile:latency_ms:0.95=p95 --having "count:>=100" -c mongodb-local-dev
}
export def "aggregate" [
  ...match: string@"mongo-filter"                 # $match filter tokens (AND-joined)
  --collection(-C): string@"mongo-collection"     # target collection (required)
  --unwind: string@"mongo-field"                  # $unwind this array field before grouping
  --by(-b): string@"mongo-fields-csv"             # $group key fields, comma-separated
  --date-bucket: string@"mongo-datebucket"        # field:unit → a $dateTrunc group key
  --agg(-a): string@"mongo-agg"                   # accumulators, comma-separated: fn:field[:param][=alias]
  --having: string@"mongo-having"                 # post-group filter tokens over result columns, comma-separated
  --sort-by(-s): string@"mongo-result-sort-csv"   # sort over result columns: "col [asc|desc]", comma-separated
  --limit(-l): int@"mongo-int-limit"
  --skip(-k): int@"mongo-int-skip"
  --connection(-c): string@"complete-connection"
  --host(-h): string@"mongo-host"
  --port(-p): int@"mongo-port"
  --user(-u): string@"mongo-user"
  --password(-P): string
  --database(-d): string@"mongo-database"
  --auth-source: string
  --uri: string
  --set: record = {}
  --raw(-R)
  --dry-run(-n)
] {
  if ($collection | is-empty) { error make {msg: "aggregate: --collection <name> is required"} }
  let by = (csv $by)
  let aggs = (csv $agg)
  if ($by | is-empty) and ($aggs | is-empty) and ($date_bucket | is-empty) {
    error make {msg: "aggregate: need at least --by, --date-bucket or --agg (use `find` for plain queries)"}
  }
  let conf = (mongo-conf $connection $host $port $user $password $database $auth_source $uri $set)
  let js = (mongo build-pipeline $collection
    --match (mongo build-filter $match)
    --unwind $unwind --by $by --date-bucket $date_bucket --agg $aggs
    --having (mongo build-filter (csv $having))
    --sort (mongo sort-spec (csv $sort_by))
    --limit $limit --skip $skip)
  if $dry_run { return {connection: ($conf | conn redact), query: $js} }
  let rows = (mongo-run $conf $js $raw)
  mongo-warm $conf
  if $raw { return $rows }
  # Mongo's $project returns lifted group keys LAST; reorder to keys-first for the
  # SQL-GROUP-BY shape (keys in --by order, then accumulators in --agg order).
  let keys = ($by ++ (if ($date_bucket | is-empty) { [] } else { [($date_bucket | split row ":" | first)] }))
  let order = ($keys ++ ($aggs | each {|t| (mongo parse-agg-token $t).alias }))
  $rows | each {|r| $r | select --optional ...$order }
}

# Run an arbitrary aggregation pipeline (the raw brother of `aggregate`).
#
# <pipeline> is a JS/JSON pipeline array (positional / `--file` / stdin / `$EDITOR`)
# run against `--collection`. For the stages `aggregate` doesn't compose — `$lookup`,
# `$facet`, `$bucket`, `$graphLookup`, `$setWindowFields`, top/bottomN, `$out`/`$merge`.
# Danger-gated (a pipeline can write via `$out`/`$merge`); `--yes` skips the prompt.
@category mole-mongodb
@example "a lookup/join pipeline" {
  mole-mongodb raw-aggregate '[{$lookup: {from: "users", localField: "customer", foreignField: "name", as: "u"}}]' -C orders -c mongodb-local-dev
}
export def "raw-aggregate" [
  pipeline?: string                               # pipeline array JS (else --file, else stdin, else $EDITOR)
  --collection(-C): string@"mongo-collection"     # target collection (required)
  --file(-f): string@"complete queryfile"
  --connection(-c): string@"complete-connection"
  --host(-h): string@"mongo-host"
  --port(-p): int@"mongo-port"
  --user(-u): string@"mongo-user"
  --password(-P): string
  --database(-d): string@"mongo-database"
  --auth-source: string
  --uri: string
  --set: record = {}
  --raw(-R)
  --dry-run(-n)
  --yes(-y)
] {
  if ($collection | is-empty) { error make {msg: "raw-aggregate: --collection <name> is required"} }
  let conf = (mongo-conf $connection $host $port $user $password $database $auth_source $uri $set)
  let pipe = ($in | query resolve $pipeline --file $file --suffix ".mongodb")
  let js = "db.getCollection(" + (mongo lit $collection) + ").aggregate(" + $pipe + ").toArray()"
  if $dry_run { return {connection: ($conf | conn redact), query: $js} }
  if (mongo is-dangerous $js (mongo mongo-danger)) and (not (query confirm "This pipeline may modify data. Run it?" --yes=$yes)) { return }
  let rows = (mongo-run $conf $js $raw)
  mongo-warm $conf
  $rows
}

# Count documents matching `find`-style filter tokens.
@category mole-mongodb
@example "how many active admins" { mole-mongodb count active role:admin -C users -c mongodb-local-dev }
export def "count" [
  ...filters: string@"mongo-filter"
  --collection(-C): string@"mongo-collection"
  --connection(-c): string@"complete-connection"
  --host(-h): string@"mongo-host"
  --port(-p): int@"mongo-port"
  --user(-u): string@"mongo-user"
  --password(-P): string
  --database(-d): string@"mongo-database"
  --auth-source: string
  --uri: string
  --set: record = {}
]: nothing -> int {
  if ($collection | is-empty) { error make {msg: "count: --collection <name> is required"} }
  let conf = (mongo-conf $connection $host $port $user $password $database $auth_source $uri $set)
  let js = "db.getCollection(" + (mongo lit $collection) + ").countDocuments(" + (mongo build-filter $filters) + ")"
  let n = (mongo-run $conf $js false)
  mongo-warm $conf
  $n
}

# Distinct values of a field with their document counts, most frequent first.
#
# Composed from `find`-style `...filters`; `--limit` caps the number of values.
# Returns a `{value, count}` table (like VictoriaLogs' `field-values`).
@category mole-mongodb
@example "which roles exist, and how common" { mole-mongodb distinct role -C users -c mongodb-local-dev }
@example "top regions among paid orders" { mole-mongodb distinct region status:paid -C orders --limit 10 -c mongodb-local-dev }
export def "distinct" [
  field: string@"mongo-field"                     # the field to enumerate
  ...filters: string@"mongo-filter"
  --collection(-C): string@"mongo-collection"
  --limit(-l): int@"mongo-int-limit"
  --connection(-c): string@"complete-connection"
  --host(-h): string@"mongo-host"
  --port(-p): int@"mongo-port"
  --user(-u): string@"mongo-user"
  --password(-P): string
  --database(-d): string@"mongo-database"
  --auth-source: string
  --uri: string
  --set: record = {}
] {
  if ($collection | is-empty) { error make {msg: "distinct: --collection <name> is required"} }
  let conf = (mongo-conf $connection $host $port $user $password $database $auth_source $uri $set)
  let fref = (mongo lit ("$" + $field))
  # NB: concatenations inside a list literal MUST be parenthesized — a bare
  # `["a" + $x]` parses `+` and the pieces as SEPARATE elements, not a concat.
  mut stages = [
    ("{$match: " + (mongo build-filter $filters) + "}")
    ("{$group: {_id: " + $fref + ", count: {$sum: 1}}}")
    "{$sort: {count: -1}}"
  ]
  if ($limit != null) { $stages = ($stages | append ("{$limit: " + ($limit | into string) + "}")) }
  $stages = ($stages | append "{$project: {_id: 0, value: \"$_id\", count: 1}}")
  let js = "db.getCollection(" + (mongo lit $collection) + ").aggregate([" + ($stages | str join ", ") + "]).toArray()"
  let rows = (mongo-run $conf $js false)
  mongo-warm $conf
  $rows
}

# List a database's collections and views: `{name, type, count, indexes}`.
@category mole-mongodb
@example "what's in the database" { mole-mongodb collections -c mongodb-local-dev }
export def "collections" [
  --connection(-c): string@"complete-connection"
  --database(-d): string@"mongo-database"
  --host(-h): string@"mongo-host"
  --port(-p): int@"mongo-port"
  --user(-u): string@"mongo-user"
  --password(-P): string
  --auth-source: string
  --uri: string
  --set: record = {}
  --refresh(-r)
] {
  let conf = (mongo-conf $connection $host $port $user $password $database $auth_source $uri $set)
  (mongo-catalog-load $conf --refresh=$refresh | get -o collections | default [])
  | each {|c| {name: $c.name, type: $c.type, count: $c.count, indexes: ($c.indexes | length)} }
}

# Inspect a connection's inferred schema (sampled; cached a day).
#
# No `--collection`: one summary row per collection ({collection, type, fields,
# count}). With `--collection`: the field detail — {name, types, nullable,
# occurrence} for each discovered field path — plus that collection's indexes.
# `--find` filters field paths by substring; `--sample` sets the docs sampled per
# collection (only takes effect with `--refresh`); `--full` returns the raw cache;
# `--refresh` rebuilds from the live database first.
@category mole-mongodb
@example "per-collection summary" { mole-mongodb schema -c mongodb-local-dev }
@example "one collection's fields and indexes" { mole-mongodb schema -C users -c mongodb-local-dev }
@example "find field paths mentioning 'city'" { mole-mongodb schema --find city -c mongodb-local-dev }
export def "schema" [
  --collection(-C): string@"mongo-collection"
  --find: string@"mongo-field"
  --sample: int@"mongo-int-sample"
  --refresh(-r)
  --full
  --connection(-c): string@"complete-connection"
  --host(-h): string@"mongo-host"
  --port(-p): int@"mongo-port"
  --user(-u): string@"mongo-user"
  --password(-P): string
  --database(-d): string@"mongo-database"
  --auth-source: string
  --uri: string
  --set: record = {}
] {
  let conf = (mongo-conf $connection $host $port $user $password $database $auth_source $uri $set)
  let data = if $sample != null { mongo-catalog-load $conf --refresh=$refresh --sample $sample } else { mongo-catalog-load $conf --refresh=$refresh }
  if $full { return $data }
  let fields = ($data | get -o fields | default [])
  if ($find | is-not-empty) {
    return ($fields | where {|f| $f.name | str contains $find })
  }
  if ($collection | is-not-empty) {
    let cols = ($fields | where collection == $collection | select name types nullable occurrence)
    let ixs = ($data | get -o collections | default [] | where name == $collection | get -o 0.indexes | default [])
    return {collection: $collection, fields: $cols, indexes: ($ixs | each {|ix| {name: $ix.name, keys: $ix.key} })}
  }
  ($data | get -o collections | default []) | each {|c|
    {collection: $c.name, type: $c.type, fields: ($fields | where collection == $c.name | length), count: $c.count}
  }
}

# List a collection's indexes: `{name, keys, unique, sparse}`.
@category mole-mongodb
@example "the indexes on orders" { mole-mongodb indexes -C orders -c mongodb-local-dev }
export def "indexes" [
  --collection(-C): string@"mongo-collection"
  --refresh(-r)
  --connection(-c): string@"complete-connection"
  --host(-h): string@"mongo-host"
  --port(-p): int@"mongo-port"
  --user(-u): string@"mongo-user"
  --password(-P): string
  --database(-d): string@"mongo-database"
  --auth-source: string
  --uri: string
  --set: record = {}
] {
  if ($collection | is-empty) { error make {msg: "indexes: --collection <name> is required"} }
  let conf = (mongo-conf $connection $host $port $user $password $database $auth_source $uri $set)
  (mongo-catalog-load $conf --refresh=$refresh | get -o collections | default [] | where name == $collection | get -o 0.indexes | default [])
  | each {|ix| {name: $ix.name, keys: ($ix | get -o key), unique: ($ix | get -o unique | default false), sparse: ($ix | get -o sparse | default false)} }
}

# Make a mongodb connection the current one for this driver.
#
# Records the choice in `$env.MOLE_CURRENT.mongodb`, so later verbs can omit
# `--connection`. Validates that `name` is a mongodb connection, and warms the
# completion catalog (sampled schema) so tab-completion is ready right away.
@category mole-mongodb
@example "make the local dev database current" { mole-mongodb set-connection mongodb-local-dev }
export def --env "set-connection" [
  name: string@"complete-connection"
]: nothing -> nothing {
  let conf = (conn resolve $name --driver mongodb)
  $env.MOLE_CURRENT = (($env.MOLE_CURRENT? | default {}) | upsert mongodb $name)
  try { mongo-catalog-load $conf --refresh | ignore } catch { }
}
