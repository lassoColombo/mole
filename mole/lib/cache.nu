# mole/lib/cache — cache storage plumbing (storage only; each driver decides
# what/when to cache). Import individually: `use mole/lib/cache` →
# `cache path`, `cache read`, `cache write`, `cache stale`, `cache fetch`, `cache clear`.
# Convention: a cached file is a record with a `meta.refreshed_at` datetime.

# The mole cache directory, honoring $env.XDG_CACHE_HOME.
#
# Returns `$XDG_CACHE_HOME/mole` when that env var is set, else `~/.cache/mole`.
@category mole-lib
@example "the cache root directory" { cache-dir }
def cache-dir []: nothing -> string {
  let xdg = $env.XDG_CACHE_HOME? | default ""
  let base = if ($xdg | is-not-empty) { $xdg } else { [$nu.home-path .cache] | path join }
  [$base mole] | path join
}

# Cache-file path for a (namespace, key) pair.
#
# Returns `<cache-dir>/<namespace>/<key>.nuon`, with any character outside
# `[A-Za-z0-9._-]` in the key replaced by `_` so it is filesystem-safe.
@category mole-lib
@example "path for a namespace/key pair" { path "sql" "prod:users" }
export def "path" [
  namespace: string   # Cache namespace, a subdirectory under the cache root (typically the driver name)
  key: string         # Cache key; sanitized into a safe filename
]: nothing -> string {
  let safe = $key | str replace --all --regex '[^A-Za-z0-9._-]' '_'
  [(cache-dir) $namespace $"($safe).nuon"] | path join
}

# Read a cache file, or null if it is missing or unreadable.
@category mole-lib
@example "read a cache file" { read "/home/me/.cache/mole/sql/prod_users.nuon" }
export def "read" [
  file: string   # Absolute path to the cache file (typically from `cache path`)
]: nothing -> any {
  if not ($file | path exists) { return null }
  try { open $file } catch { null }
}

# Write the piped data to a cache file, creating parent directories as needed.
#
# The data is serialized to NUON. By convention a cached value is a record with a
# `meta.refreshed_at` datetime so `cache stale` can judge its age.
@category mole-lib
@example "cache a value with a refresh timestamp" {
  {meta: {refreshed_at: (date now)}, rows: []} | write (path "sql" "prod:users")
}
export def "write" [
  file: string   # Absolute destination path (typically from `cache path`)
]: any -> nothing {
  let data = $in
  mkdir ($file | path dirname)
  $data | to nuon | save -f $file
}

# Whether a cache file is stale.
#
# True when the file is missing, unreadable, lacks a `meta.refreshed_at`, or its
# `refreshed_at` is older than `ttl` from now.
@category mole-lib
@example "is the cache older than an hour?" { stale (path "sql" "prod:users") 1hr }
export def "stale" [
  file: string     # Absolute path to the cache file
  ttl: duration    # Maximum age before the cache is considered stale (e.g. 1hr, 30min)
]: nothing -> bool {
  let data = read $file
  if ($data | is-empty) { return true }
  let when = $data | get -o meta | get -o refreshed_at
  if ($when | is-empty) { return true }
  ((date now) - $when) > $ttl
}

# Serve a cached record, or (re)build it — the one memoize primitive behind every
# driver's catalog/schema loader.
#
# Returns `read $file` when the file is fresh (younger than `ttl`) and `--refresh`
# is not given. Otherwise runs `build`, stamps `meta.refreshed_at` with the current
# time (the convention `stale` keys off — any other `meta` fields `build` set are
# kept), writes the result to `file`, and returns it. A failing `build` propagates
# (nothing is written).
@category mole-lib
@example "serve for a day, rebuilding from the closure when stale or on --refresh" {
  fetch (path "sql" "prod:users") 1day {|| {meta: {connection: "prod"}, tables: []} }
}
export def "fetch" [
  file: string      # Absolute path to the cache file (typically from `cache path`)
  ttl: duration     # Maximum age before the cache is rebuilt
  build: closure    # {|| -> record} produces the value to cache
  --refresh         # Rebuild even when the cache is fresh
]: nothing -> any {
  if (not $refresh) and (not (stale $file $ttl)) { return (read $file) }
  let built = (do $build)
  let meta = ($built | get -o meta | default {} | upsert refreshed_at (date now))
  let data = ($built | upsert meta $meta)
  $data | write $file
  $data
}

# Delete a cache file if it exists (no-op otherwise).
@category mole-lib
@example "drop a cached entry" { clear (path "sql" "prod:users") }
export def "clear" [
  file: string   # Absolute path to the cache file to remove
]: nothing -> nothing {
  if ($file | path exists) { rm $file }
}
