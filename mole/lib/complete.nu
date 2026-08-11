# mole/lib/complete — shared tab-completers. Import individually:
# `use mole/lib/complete` → `complete connection`, `complete queryfile`.
# Callers annotate flags with `@"complete connection"` / `@"complete queryfile"`.

use ./conn.nu
use ./config.nu
use ./cache.nu

# Completer: ALL configured connection names, across every driver.
#
# For mole's cross-driver management surface (`mole cfg show`). A driver's OWN
# verbs must NOT use this — they scope to their own connections via `conn names
# "<driver>"` (wrapped in a tiny local completer). Attach with
# `name: string@"complete connection"`.
@category mole-lib
@example "connection-name suggestions (all drivers)" { connection }
export def "connection" []: nothing -> list<string> {
  conn list | get -o name | default []
}

# Completer: saved query files, recursively, as paths relative to the query dir.
#
# Returns an empty list when the query directory does not exist. Attach to a
# parameter with `f: string@"complete queryfile"`.
@category mole-lib
@example "saved-query suggestions" { queryfile }
export def "queryfile" []: nothing -> list<string> {
  let base = config querydir
  if not ($base | path exists) { return [] }
  glob --no-dir ([$base "**" "*"] | path join | into glob)
  | each {|f| $f | str replace $"($base)/" "" }
}

# ---- contextual completion toolkit --------------------------------------------
# Every driver's completers are the same pipeline — parse the partial command line,
# resolve the connection/catalog it targets, produce candidates — re-implemented
# per module. These are the shared PARSE + RESOLVE building blocks; all NEVER throw,
# so a completer never needs its own try/catch and a Tab never errors. A per-flag
# `def "x" [ctx: string] { ... }` wrapper still exists (Nushell needs a named def
# per @annotation), but its body collapses to a composed one-liner.

# Flatten the completion context into quote-aware ast tokens ([{content, shape,
# span}]); [] when `ast` can't parse the (often partial) line.
def tokens [context: string]: nothing -> list {
  try { ast $context --flatten --json | from json } catch { [] }
}

# Strip one matching pair of surrounding quotes from a token value.
def unquote [s: string]: nothing -> string {
  let len = ($s | str length)
  if $len < 2 { return $s }
  let d = ($s | str substring 0..0)
  if ($d in ['"' "'"]) and ($s | str ends-with $d) { $s | str substring 1..($len - 2) } else { $s }
}

# The current partial token: the last whitespace-delimited chunk of the context,
# "" when the cursor sits after a space (a fresh word). Two-stage `field:value`
# completers branch on it, so it matches the old per-driver `*-token` helpers.
@category mole-lib
@example "the token being typed" { token "select id --from us" } --result "us"
@example "a trailing space is a fresh word" { token "select id " } --result ""
export def "token" [context: string]: nothing -> string {
  $context | split row " " | last
}

# The value a value-flag already carries on the line, quote-aware. `names` are the
# spellings to try (long + short); `--from "users u"` yields `users u` as ONE token
# (a regex split would stop at the space). `--flag=value` is handled; the last
# occurrence wins; null when the flag is absent. The ast-based replacement for the
# per-library `parse-flag` / `vl-flag`.
@category mole-lib
@example "read a flag the user typed" { flag "select --from public.users -c prod" [--connection -c] } --result "prod"
@example "a quoted value stays whole" { flag 'select --from "users u"' [--from -F] } --result "users u"
@example "null when the flag is absent" { flag "select 1" [--from -F] } --result null
export def "flag" [
  context: string
  names: list<string>   # flag spellings to try, e.g. [--from -F]
]: nothing -> any {
  let want = ($names | each {|n| $n | into string })
  let toks = (tokens $context)
  let hits = ($toks | enumerate | where {|t|
    let c = ($t.item.content | into string)
    ($c in $want) or ($want | any {|w| $c | str starts-with ($w + "=") })
  })
  if ($hits | is-empty) { return null }          # flag absent
  let hit = ($hits | last)                        # last occurrence wins
  let c = ($hit.item.content | into string)
  let val = if ($c | str contains "=") {
    ($c | str replace --regex '^[^=]*=' '')       # --flag=value
  } else {
    let nxt = ($toks | get -o ($hit.index + 1) | get -o content)
    if ($nxt != null) and (not ($nxt | into string | str starts-with "-")) { ($nxt | into string) } else { null }
  }
  if ($val == null) { null } else { unquote ($val | into string) }
}

# Resolve the connection a completion line targets, robustly and never throwing.
# Precedence: a typed `--connection`/`-c` → the session-current
# (`$env.MOLE_CURRENT.<driver>`) → the cached `<driver>/__current__` name — the
# last matters because completion often can't see the session env, which is exactly
# why `set-connection` mirrors the choice into that cache file. `--over` layers on
# extra overrides (e.g. a `--database` typed on the line). Null when nothing resolves.
@category mole-lib
@example "resolve for the psql driver" { conn-ctx "select --from t -c prod" "psql" }
export def "conn-ctx" [
  context: string
  driver: string
  --over: record = {}   # extra field overrides to apply (e.g. {database: ...})
]: nothing -> any {
  let named = (flag $context ["--connection" "-c"])
  let cur = ($env.MOLE_CURRENT? | default {} | get -o $driver)
  let filed = (try { cache read (cache path $driver "__current__") | get -o name } catch { null })
  let name = ([$named $cur $filed] | where {|x| $x | is-not-empty } | get -o 0)
  if ($name | is-empty) { return null }
  try { conn resolve $name --driver $driver | conn override $over } catch { null }
}

# The cached catalog for whatever connection the line targets, never throwing.
# `--get {|conf| ...}` fetches the catalog from the resolved connection; the default
# reads the name-keyed cache file, and a driver whose cache key includes the database
# (or that warms on a cold miss) injects its own getter. Returns {} when nothing
# resolves or on any error, so the caller's extractor (`sql complete-tables`,
# `get -o metrics`, …) sees an empty catalog and yields no candidates.
@category mole-lib
@example "the psql schema cache the line targets" {
  catalog-ctx "select --from t -c prod" "psql" --get {|c| pg-schema-load $c }
}
export def "catalog-ctx" [
  context: string
  driver: string
  --get: closure        # {|conf| -> catalog record}; default = read the name-keyed cache file
]: nothing -> record {
  let conf = (conn-ctx $context $driver)
  if ($conf | is-empty) { return {} }
  let getter = if ($get == null) { {|c| cache read (cache path $driver ($c | get -o name | default "_")) } } else { $get }
  try { (do $getter $conf) | default {} } catch { {} }
}
