#!/usr/bin/env nu
# run-tests.nu — run every module's nutest suite in this workspace (or one, with --path).
#
# Requirements (both via `$env.NU_LIB_DIRS`, set BEFORE launching nu):
#   - a directory containing `nutest/` (the importable module of github.com/vyadh/nutest)
#   - this workspace root, so cross-module imports (`use mole-sql/sql.nu`, `use mole-mysql`)
#     resolve inside the suites. The script adds its own directory if it is missing.
#
# WHY the `with-env` dance: nutest discovers and runs each suite in a
# `nu --no-config-file` SUBPROCESS. A list-valued `$env.NU_LIB_DIRS` (what env.nu
# sets) has no ENV_CONVERSIONS entry, so Nushell silently DROPS it when spawning
# children, and every suite that imports another module dies at parse with
# "module not found". Handing the children an OS colon-string works.
#
#   nu run-tests.nu                 # every */tests
#   nu run-tests.nu --path mole-sql # one module
#   nu run-tests.nu --fail          # non-zero exit on any failure (CI)

use nutest

# `$env.NU_LIB_DIRS` as a colon-string that also carries this workspace root.
def lib-dirs []: nothing -> string {
  let current = ($env.NU_LIB_DIRS? | default [])
  let dirs = if ($current | describe) == "string" { $current | split row (char esep) } else { $current }
  $dirs | append $env.FILE_PWD | uniq | str join (char esep)
}

# Every `<module>/tests` directory under the workspace root, sorted.
def suites []: nothing -> list<string> {
  glob ([$env.FILE_PWD "*" "tests"] | path join | into glob)
  | where {|p| ($p | path type) == "dir" }
  | sort
}

def main [
  --path(-p): string   # one module directory (relative to the workspace root or absolute); default: all
  --fail               # exit non-zero when any suite has failures
]: nothing -> table {
  let targets = if ($path | is-not-empty) {
    [([$env.FILE_PWD $path tests] | path join)]
  } else {
    suites
  }
  let results = with-env { NU_LIB_DIRS: (lib-dirs) } {
    $targets | each {|t|
      let s = (nutest run-tests --path $t --returns summary)
      if $s.failed > 0 {
        # Re-run the failing suite with the full result table so the failures are visible.
        print $"(ansi red)FAILURES in ($t)(ansi reset)"
        nutest run-tests --path $t --returns table | where result == "FAIL" | each {|r|
          print $"- ($r.suite) :: ($r.test)\n($r.output | to text)"
        } | ignore
      }
      {module: ($t | path dirname | path basename)} | merge $s
    }
  }
  let failed = ($results | get failed | math sum)
  if $fail and $failed > 0 {
    error make {msg: $"($failed) test\(s) failed"}
  }
  $results
}
