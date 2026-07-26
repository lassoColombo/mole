# mole/lib/query — the query-running toolkit: resolve query text, confirm before
# running, check the external result. Import individually: `use ../mole/lib/query`
# → `query resolve`, `query confirm`, `query check`.
# (`query confirm` was the old `confirm`; `query check` was the old `sh check`.)

use ./config.nu
use ./complete.nu

# Resolve query text, from a saved file or an interactive editor session.
#
# With `--file`, reads that saved query (a path relative to the query dir) as raw
# text. Otherwise opens $EDITOR on a fresh temp file (named with `--suffix`) and
# returns whatever was written.
@category mole-lib
@example "load a saved query" { resolve --file "reports/daily.sql" }
@example "compose a query in \$EDITOR with a .sql temp file" { resolve --suffix ".sql" }
export def "resolve" [
  --file(-f): string@"complete queryfile"   # Saved query to read, relative to the query dir; omit to open an editor
  --suffix: string = ".txt"    # Temp-file suffix for the editor session (sets the editor's syntax mode)
]: nothing -> string {
  if ($file | is-not-empty) {
    return (open -r ([(config querydir) $file] | path join))
  }
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
