# mole/lib/complete — shared tab-completers. Import individually:
# `use ../mole/lib/complete` → `complete connection`, `complete queryfile`.
# Callers annotate flags with `@"complete connection"` / `@"complete queryfile"`.

use ./conn.nu
use ./config.nu

# Completer: ALL configured connection names, across every source.
#
# For mole's cross-source management surface (`mole cfg show`). A source's OWN
# verbs must NOT use this — they scope to their own connections via `conn names
# "<source>"` (wrapped in a tiny local completer). Attach with
# `name: string@"complete connection"`.
@category mole-lib
@example "connection-name suggestions (all sources)" { connection }
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
