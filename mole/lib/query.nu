# mole/lib/query — the query-running toolkit: resolve query text, confirm before
# running, check the external result. Import individually: `use mole/lib/query`
# → `query resolve`, `query confirm`, `query check`.
# (`query confirm` was the old `confirm`; `query check` was the old `sh check`.)

use ./config.nu
use ./complete.nu

# Resolve query text from the first available source, in precedence order:
# inline `text`, a saved `--file`, piped stdin, then an interactive `$EDITOR`
# session. Submodule verbs call it as `$in | query resolve $sql --file $file
# --suffix ".sql"`, so the query can arrive as the verb's positional, a saved
# file, or a pipeline — e.g. `mole query show reports/daily.sql | mole-psql raw-query`.
#
# `text` (an explicit argument) wins; then `--file` reads that saved query (a
# path relative to the query dir) as raw text; then non-empty piped input is used
# verbatim (coerced to a string); with none of those, opens $EDITOR on a fresh
# temp file (named with `--suffix`) and returns whatever was written.
@category mole-lib
@example "inline text wins over the pipeline" { "SELECT 1" | resolve "SELECT 2" } --result "SELECT 2"
@example "fall back to piped stdin" { "SELECT 1" | resolve } --result "SELECT 1"
@example "load a saved query" { resolve --file "reports/daily.sql" }
@example "compose a query in \$EDITOR with a .sql temp file" { resolve --suffix ".sql" }
export def "resolve" [
  text?: string                             # Inline query text; wins over --file, stdin, and $EDITOR
  --file(-f): string@"complete queryfile"   # Saved query to read, relative to the query dir
  --suffix: string = ".txt"    # Temp-file suffix for the editor session (sets the editor's syntax mode)
]: any -> string {
  let piped = $in
  if ($text | is-not-empty) { return $text }
  if ($file | is-not-empty) {
    return (open -r ([(config querydir) $file] | path join))
  }
  if ($piped | is-not-empty) { return ($piped | into string) }
  let tmp = mktemp --suffix $suffix
  nu -c $"($env.EDITOR) ($tmp)"
  open -r $tmp
}

# Reusable yellow y/N confirmation prompt.
#
# Prints `message` and reads a single character; returns true only when the user
# answers `y`. Defaults to no. `--yes` skips the prompt and returns true — for
# non-interactive / forced runs.
@category mole-lib
@example "ask before a destructive action" { confirm "Drop the table?" }
@example "force-confirm in a script" { confirm "Drop the table?" --yes } --result true
export def "confirm" [
  message: string   # The prompt text shown before ` [y/N]`
  --yes             # Skip the prompt and return true (assume yes)
]: nothing -> bool {
  if $yes { return true }
  # `input` throws an I/O error when there is no TTY (scripts, `nu -c`, pipelines).
  # Degrade to "no" with a clear note instead of failing the whole command.
  let ans = try {
    input $"(ansi yellow)($message) [y/N](ansi reset) " --numchar 1 --default 'n'
  } catch {
    print -e $"(ansi yellow)($message)(ansi reset) [no input available — assuming No; pass --yes to run]"
    'n'
  }
  ($ans | str lowercase) == 'y'
}

# Unwrap a `complete` record: raise on failure, else return stdout.
#
# Takes the record produced by piping an external command through `complete`. On
# a nonzero exit code it raises an error carrying the combined stderr+stdout;
# otherwise it returns stdout.
@category mole-lib
@example "run an external command and get its output or raise" { ^psql -c "select 1" | complete | check }
export def "check" []: record -> string {
  let r = $in
  if $r.exit_code != 0 {
    error make {msg: ($"($r.stderr)\n($r.stdout)" | str trim)}
  }
  $r.stdout
}

# Test a statement against a caller-supplied dangerous-statement regex.
#
# The caller owns `pattern` (its dialect's write / DDL / session-mutating keywords)
# and calls this before running to decide whether to prompt. String literals and
# quoted identifiers are stripped FIRST — single- and double-quoted spans (honoring
# BOTH the SQL `''`/`""` doubling and the JS/mongosh `\'`/`\"` backslash escape
# conventions) plus `` `...` `` spans — so a keyword that appears only inside a
# `'...'` value, a `LIKE` pattern, a `"..."` / `` `...` `` identifier, or a mongosh
# string field can't trip the check; only keywords in real statement positions
# count. (Without this a read-only `... WHERE name LIKE '%create%'` would falsely
# prompt.) Dialect-agnostic: shared by the SQL drivers (`pattern` = their danger
# regex) and mongodb (`pattern` = `mongo mongo-danger`). Case-sensitivity is
# whatever the pattern encodes — the dialect patterns lead with `(?i)`.
@category mole-lib
@example "a DROP is flagged" {
  is-dangerous "DROP TABLE x" '(?i)\b(drop|delete)\b'
} --result true
@example "a plain SELECT is not" {
  is-dangerous "select 1" '(?i)\b(drop|delete)\b'
} --result false
@example "a keyword inside a string literal does not count" {
  is-dangerous "SELECT id FROM t WHERE name LIKE '%drop%'" '(?i)\b(drop|delete)\b'
} --result false
export def "is-dangerous" [
  text: string      # the statement to test
  pattern: string   # the caller's dangerous-statement regex (dialect-specific)
]: nothing -> bool {
  let bare = ($text
    | str replace --all --regex "'(?:[^'\\\\]|''|\\\\.)*'" " "   # single-quoted spans ('' or \-escapes)
    | str replace --all --regex '"(?:[^"\\]|""|\\.)*"' " "       # double-quoted spans / identifiers
    | str replace --all --regex '`[^`]*`' " ")                   # backtick identifiers / template literals
  $bare =~ $pattern
}
