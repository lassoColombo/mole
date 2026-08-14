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
#     lazy three-tier completion catalog (cheap skeleton + per-collection sampled
#     schema + a metadata sweep, each cached a day — see the catalog section), and
#     turning payloads into typed rows. Read-oriented is structural; only the two
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

# ---- completion catalog (lazy, three tiers) ------------------------------------
#
# The old design eagerly sampled EVERY collection of the current database whenever
# the catalog was (re)built — fine for a demo DB, fatal for a production `logs`
# database with huge/many collections: `set-connection` would sample the whole
# thing and hang. The catalog is now split so we only ever pay for what we touch:
#   1. SKELETON  (mongo-skeleton-js)  — db names + collection names/types. Two
#      metadata round-trips, no per-collection work; instant at any DB size. Feeds
#      the collection/database completers. Built by set-connection and warm-on-miss.
#   2. PER-COLLECTION (mongo-collschema-js) — one collection's count + indexes +
#      $sample→inferred fields. Built lazily the first time that collection's fields
#      are completed or `schema -C`/`indexes -C` inspects it. Samples ONE collection.
#   3. COLLMETA  (mongo-collmeta-js)  — per-collection count + index count across all
#      collections, WITHOUT sampling and WITHOUT any full-scan count fallback. Built
#      only by the explicit `collections`/`schema` summary verbs, then cached.

# Tier 1. Database names + non-system collection names/types, in one round-trip.
# getDBNames is wrapped so a missing listDatabases privilege still yields the
# collection list (the part completion needs most).
def mongo-skeleton-js []: nothing -> string {
  r#'(function(){
  let dbs = []; try { dbs = db.getMongo().getDBNames(); } catch(e) {}
  const colls = db.getCollectionInfos().filter(c => !c.name.startsWith("system."))
    .map(c => ({name: c.name, type: c.type}));
  return {databases: dbs, collections: colls};
})()'#
}

# Tier 2. One collection's schema material: an ESTIMATED count (never a
# countDocuments full scan — a huge collection must not block a keystroke), its
# indexes, and a $sample of docs (views can't $sample → fall back to a limited
# find). Field inference runs in nu via `mongo infer-schema`.
def mongo-collschema-js [coll: string, sample: int]: nothing -> string {
  let tmpl = r#'(function(){
  const coll = db.getCollection(__COLL__);
  let count = null; try { count = coll.estimatedDocumentCount(); } catch(e) {}
  let indexes = []; try { indexes = coll.getIndexes(); } catch(e) {}
  let sample = [];
  try { sample = coll.aggregate([{$sample: {size: __SAMPLE__}}]).toArray(); }
  catch(e) { try { sample = coll.find().limit(__SAMPLE__).toArray(); } catch(e2) {} }
  return {count: count, indexes: indexes, sample: sample};
})()'#
  $tmpl | str replace --all "__COLL__" (mongo lit $coll) | str replace --all "__SAMPLE__" ($sample | into string)
}

# Tier 3. Per-collection metadata across the whole database — name, type, estimated
# count (never a full scan), index count — WITHOUT sampling. O(#collections) metadata
# reads; run only by the explicit `collections`/`schema` verbs and then cached.
def mongo-collmeta-js []: nothing -> string {
  r#'(function(){
  return db.getCollectionInfos().filter(c => !c.name.startsWith("system.")).map(function(c){
    const coll = db.getCollection(c.name);
    let count = null; try { count = coll.estimatedDocumentCount(); } catch(e) {}
    let indexes = 0; try { indexes = coll.getIndexes().length; } catch(e) {}
    return {name: c.name, type: c.type, count: count, indexes: indexes};
  });
})()'#
}

# Cache-file paths, all namespaced by connection + database. The three tiers live
# in separate directories so a collection named e.g. `meta` can't collide with the
# collmeta file (sanitized keys can't be told apart otherwise).
def mongo-cache-file [conf: record]: nothing -> string {   # tier 1 (skeleton)
  let db = ($conf | get -o database | default "_")
  cache path "mongodb" $"(($conf | get -o name) | default '_')__($db)"
}
def mongo-collcache-file [conf: record, coll: string]: nothing -> string {   # tier 2
  let db = ($conf | get -o database | default "_")
  cache path "mongodb/fields" $"(($conf | get -o name) | default '_')__($db)__($coll)"
}
def mongo-collmeta-file [conf: record]: nothing -> string {   # tier 3
  let db = ($conf | get -o database | default "_")
  cache path "mongodb/meta" $"(($conf | get -o name) | default '_')__($db)"
}

# Tier 1 loader — the skeleton (db names + collection names/types), rebuilt on
# --refresh or when stale (1 day). System databases are dropped. `--fast` bounds
# server selection so a dead server fails a keystroke quickly instead of hanging.
def mongo-skeleton-load [conf: record, --refresh, --fast]: nothing -> record {
  let file = (mongo-cache-file $conf)
  if (not $refresh) and (not (cache stale $file 1day)) { return (cache read $file) }
  let decoded = (mongo ejson-decode (mongo-exec $conf (mongo-skeleton-js) --fast=$fast))
  let data = {
    meta: {connection: ($conf | get -o name), database: ($conf | get -o database | default "_"), driver: "mongodb", refreshed_at: (date now)}
    databases: ($decoded | get -o databases | default [] | where {|d| $d not-in ["admin" "config" "local"] })
    collections: ($decoded | get -o collections | default [])
  }
  $data | cache write $file
  $data
}

# Tier 2 loader — one collection's `{count, indexes, fields}`, sampled + inferred.
# Rebuilt on --refresh or when stale. This is the ONLY sampling path, and it touches
# a single collection, so it stays cheap however large the database is.
def mongo-collschema-load [conf: record, coll: string, --refresh, --sample: int = 100, --fast]: nothing -> record {
  let file = (mongo-collcache-file $conf $coll)
  if (not $refresh) and (not (cache stale $file 1day)) { return (cache read $file) }
  let decoded = (mongo ejson-decode (mongo-exec $conf (mongo-collschema-js $coll $sample) --fast=$fast))
  let data = {
    meta: {connection: ($conf | get -o name), database: ($conf | get -o database | default "_"), collection: $coll, driver: "mongodb", refreshed_at: (date now)}
    collection: $coll
    count: ($decoded | get -o count)
    indexes: ($decoded | get -o indexes | default [])
    fields: (mongo infer-schema ($decoded | get -o sample | default []))
  }
  $data | cache write $file
  $data
}

# Tier 3 loader — per-collection metadata across the whole DB (name/type/count/
# #indexes), no sampling. Returns the collection list; cached under its own key.
def mongo-collmeta-load [conf: record, --refresh, --fast]: nothing -> list {
  let file = (mongo-collmeta-file $conf)
  if (not $refresh) and (not (cache stale $file 1day)) { return (cache read $file | get -o collections | default []) }
  let colls = (mongo ejson-decode (mongo-exec $conf (mongo-collmeta-js) --fast=$fast) | default [])
  {
    meta: {connection: ($conf | get -o name), database: ($conf | get -o database | default "_"), driver: "mongodb", refreshed_at: (date now)}
    collections: $colls
  } | cache write $file
  $colls
}

# Warm the SKELETON after a successful query, but only when cold (missing).
# Best-effort — the connection is known reachable here, so it never breaks the call.
# Per-collection field schemas are NOT warmed here; they load lazily on first use.
def mongo-warm [conf: record]: nothing -> nothing {
  if (cache read (mongo-cache-file $conf) | is-not-empty) { return }
  try { mongo-skeleton-load $conf | ignore } catch { }
}

# ---- completion helpers --------------------------------------------------------

# The token under the cursor: the last whitespace-delimited chunk of the context.
def mongo-token [ctx: string]: nothing -> string { $ctx | split row " " | last }

# The resolved connection a completion line names (via `-c`/`--connection` and an
# optional `--database` override), or the current one. Null when nothing resolves.
def mongo-ctx-conf [ctx: string]: nothing -> any {
  complete conn-ctx $ctx mongodb --over {database: (complete flag $ctx [--database -d])}
}

# The SKELETON (db + collection names) for whatever connection/database the line
# names. A warm cache is served as-is — instant, even if a day stale (no rebuild on a
# keystroke). COLD (e.g. a `--database` override never queried) → the skeleton is
# built live ONCE (best-effort, fast server-selection timeout) and cached, so
# collection/database completion works for that database too. Nothing resolves → {}.
def mongo-cache-ctx [ctx: string]: nothing -> record {
  let conf = (mongo-ctx-conf $ctx)
  if ($conf | is-empty) { return {} }
  try {
    let cached = (cache read (mongo-cache-file $conf))
    if ($cached | is-not-empty) { return $cached }
    mongo-skeleton-load $conf --fast
  } catch { {} }
}

# Field records for a collection (tier 2). A NAMED collection warms on miss — sampled
# live ONCE (fast timeout) and cached — so field completion works even for a
# collection never queried, without ever sampling the rest of the database. With NO
# collection there is no cheap "all fields", so we return the UNION of collections
# already sampled for this (connection, database) — read-only, never triggers a
# sample. Filtered by the stored meta, so it's robust to key sanitization.
def mongo-collfields [conf: any, coll: string]: nothing -> list {
  if ($conf | is-empty) { return [] }
  if ($coll | is-not-empty) {
    let cached = (cache read (mongo-collcache-file $conf $coll))
    let data = if ($cached | is-not-empty) { $cached } else { (try { mongo-collschema-load $conf $coll --fast } catch { {} }) }
    return ($data | get -o fields | default [] | each {|f| {collection: $coll} | merge $f })
  }
  let dir = (mongo-collcache-file $conf "_" | path dirname)
  if not ($dir | path exists) { return [] }
  let cn = ($conf | get -o name)
  let dbn = ($conf | get -o database | default "_")
  try {
    ls ($dir | path join "*.nuon") | get name | each {|p| cache read $p }
    | where {|d| ($d | get -o meta.connection) == $cn and (($d | get -o meta.database | default "_") == $dbn) }
    | each {|d| ($d | get -o fields | default []) | each {|f| {collection: ($d | get -o meta.collection)} | merge $f } }
    | flatten
  } catch { [] }
}

# Sorted, deduped field names for the `--collection` on the line (see mongo-collfields).
def mongo-fields-for [ctx: string]: nothing -> list<string> {
  let coll = (mongo parse-flag $ctx ["--collection" "-C"])
  mongo-collfields (mongo-ctx-conf $ctx) $coll | get -o name | default [] | uniq | sort
}

# The result columns an `aggregate` produces, derived from the `--by`/`--date-bucket`
# group keys and the `--agg` accumulator aliases ALREADY on the line — so `--having`
# and `--sort-by` complete columns that don't exist until the aggs are typed.
def mongo-result-cols [ctx: string]: nothing -> list<string> {
  let by = (complete csv (mongo parse-flag $ctx ["--by" "-b"]))
  let dbk = (mongo parse-flag $ctx ["--date-bucket"])
  let bydate = if ($dbk | is-not-empty) { [($dbk | split row ":" | first)] } else { [] }
  let aliases = (complete csv (mongo parse-flag $ctx ["--agg" "-a"]) | each {|t| try { (mongo parse-agg-token $t).alias } catch { null } } | where {|x| $x != null })
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
    mongo-collfields (mongo-ctx-conf $ctx) $coll
    | where {|f| "datetime" in ($f | get -o types | default []) }
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
  if (query is-dangerous $js (mongo mongo-danger)) and (not (query confirm "This may modify data. Run it?" --yes=$yes)) { return }
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
  let proj = (mongo projection-spec (complete csv $select) (complete csv $exclude))
  let sort = (mongo sort-spec (complete csv $sort_by))
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
  let by = (complete csv $by)
  let aggs = (complete csv $agg)
  if ($by | is-empty) and ($aggs | is-empty) and ($date_bucket | is-empty) {
    error make {msg: "aggregate: need at least --by, --date-bucket or --agg (use `find` for plain queries)"}
  }
  let conf = (mongo-conf $connection $host $port $user $password $database $auth_source $uri $set)
  let js = (mongo build-pipeline $collection
    --match (mongo build-filter $match)
    --unwind $unwind --by $by --date-bucket $date_bucket --agg $aggs
    --having (mongo build-filter (complete csv $having))
    --sort (mongo sort-spec (complete csv $sort_by))
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
  --yes(-y)
] {
  if ($collection | is-empty) { error make {msg: "raw-aggregate: --collection <name> is required"} }
  let conf = (mongo-conf $connection $host $port $user $password $database $auth_source $uri $set)
  let pipe = ($in | query resolve $pipeline --file $file --suffix ".mongodb")
  let js = "db.getCollection(" + (mongo lit $collection) + ").aggregate(" + $pipe + ").toArray()"
  if (query is-dangerous $js (mongo mongo-danger)) and (not (query confirm "This pipeline may modify data. Run it?" --yes=$yes)) { return }
  let rows = (mongo-run $conf $js $raw)
  mongo-warm $conf
  $rows
}

# Count documents matching `find`-style filter tokens. `--dry-run` returns
# `{connection, query}` — the composed `countDocuments(...)` — without running.
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
  --dry-run(-n)
] {
  if ($collection | is-empty) { error make {msg: "count: --collection <name> is required"} }
  let conf = (mongo-conf $connection $host $port $user $password $database $auth_source $uri $set)
  let js = "db.getCollection(" + (mongo lit $collection) + ").countDocuments(" + (mongo build-filter $filters) + ")"
  if $dry_run { return {connection: ($conf | conn redact), query: $js} }
  let n = (mongo-run $conf $js false)
  mongo-warm $conf
  $n
}

# Distinct values of a field with their document counts, most frequent first.
#
# Composed from `find`-style `...filters`; `--limit` caps the number of values.
# Returns a `{value, count}` table (like VictoriaLogs' `field-values`). `--dry-run`
# returns `{connection, query}` without running.
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
  --dry-run(-n)
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
  if $dry_run { return {connection: ($conf | conn redact), query: $js} }
  let rows = (mongo-run $conf $js false)
  mongo-warm $conf
  $rows
}

# List a database's collections and views: `{name, type, count, indexes}`.
#
# `count` is an ESTIMATE (metadata, never a full scan) and `indexes` is the index
# count. Gathered in one metadata sweep and cached a day (`--refresh` rebuilds) — no
# document sampling, so it's safe on a large database.
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
  mongo-collmeta-load $conf --refresh=$refresh
  | each {|c| {name: $c.name, type: $c.type, count: ($c | get -o count), indexes: ($c | get -o indexes | default 0)} }
}

# Inspect a connection's inferred schema (sampled per collection, cached a day).
#
# With `--collection`: samples THAT collection and returns its field detail —
# {name, types, nullable, occurrence} per discovered path — plus its count and
# indexes. Without `--collection`: a lightweight summary row per collection
# ({collection, type, count, fields, indexes}) built from the metadata sweep — `fields`
# is the field count for collections already sampled (via `schema -C`), else null (no
# whole-database sampling). `--find <substr>` filters field paths, but only across
# collections already sampled. `--sample` sets the docs sampled (with `-C`, on
# --refresh/stale); `--full` returns the raw cache; `--refresh` rebuilds live first.
@category mole-mongodb
@example "per-collection summary" { mole-mongodb schema -c mongodb-local-dev }
@example "one collection's fields and indexes" { mole-mongodb schema -C users -c mongodb-local-dev }
@example "find field paths mentioning 'city' (among sampled collections)" { mole-mongodb schema --find city -c mongodb-local-dev }
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
  # --collection: sample just that collection (tier 2).
  if ($collection | is-not-empty) {
    let data = if $sample != null { mongo-collschema-load $conf $collection --refresh=$refresh --sample $sample } else { mongo-collschema-load $conf $collection --refresh=$refresh }
    if $full { return $data }
    let cols = ($data | get -o fields | default [] | select name types nullable occurrence)
    let ixs = ($data | get -o indexes | default [])
    return {collection: $collection, count: ($data | get -o count), fields: $cols, indexes: ($ixs | each {|ix| {name: $ix.name, keys: $ix.key} })}
  }
  # No collection: the metadata sweep (tier 3), never sampling the whole database.
  let colls = (mongo-collmeta-load $conf --refresh=$refresh)
  if $full { return $colls }
  if ($find | is-not-empty) {
    # Field search spans only collections already sampled (their tier-2 cache).
    return ($colls | each {|c|
      let cf = (cache read (mongo-collcache-file $conf $c.name))
      if ($cf | is-empty) { [] } else {
        ($cf | get -o fields | default [] | where {|f| $f.name | str contains $find } | each {|f| {collection: $c.name} | merge ($f | select name types nullable occurrence) })
      }
    } | flatten)
  }
  $colls | each {|c|
    let cf = (cache read (mongo-collcache-file $conf $c.name))
    {collection: $c.name, type: $c.type, count: ($c | get -o count), fields: (if ($cf | is-empty) { null } else { ($cf | get -o fields | default [] | length) }), indexes: ($c | get -o indexes | default 0)}
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
  (mongo-collschema-load $conf $collection --refresh=$refresh | get -o indexes | default [])
  | each {|ix| {name: $ix.name, keys: ($ix | get -o key), unique: ($ix | get -o unique | default false), sparse: ($ix | get -o sparse | default false)} }
}

# Make a mongodb connection the current one for this driver.
#
# Records the choice in `$env.MOLE_CURRENT.mongodb`, so later verbs can omit
# `--connection`. Validates that `name` is a mongodb connection, and warms only the
# lightweight SKELETON (database + collection names) — a fast, bounded metadata
# round-trip, so this returns promptly even against a huge database. Per-collection
# field schemas load lazily on first use, never here.
@category mole-mongodb
@example "make the local dev database current" { mole-mongodb set-connection mongodb-local-dev }
export def --env "set-connection" [
  name: string@"complete-connection"
]: nothing -> nothing {
  let conf = (conn set-current mongodb $name)
  try { mongo-skeleton-load $conf --refresh --fast | ignore } catch { }
}
