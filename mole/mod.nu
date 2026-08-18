# mole — the standalone core module for the mole ecosystem.
#
# ARCHITECTURE (see DESIGN.md). mole is a foundation that submodules
# depend on, never the other way around. mole never imports, enumerates, or
# generates anything about submodules — installing one is only cloning a sibling
# repo. No umbrella, no `sync`/codegen step. Import rule everywhere: `use module`,
# never `use module *`.
#
# This file COMPOSES the user-facing `mole` module from:
#   - ./cfg.nu   → `mole cfg show/file/dir/edit`   (connection config)
#   - `mole query edit/show/dir` below             (saved queries)
# and nothing more. The PLUMBING lives in ./lib/* and is imported PRIVATELY here
# (and directly by submodules via `use mole/lib/<concern>`), so `use mole`
# exposes only management commands — never the plumbing.
#
# NOTE: submodule management (`mole submodules …`) and the version/compatibility
# contract were removed for now — mole is currently just config + query
# management plus the shared lib/ plumbing. Submodules still self-register into
# `$env.MOLE_REGISTRY` at load via `conn register "<driver>"` (powering `--driver`
# resolution — a set of loaded driver names, no manifest file), and they import
# lib concerns directly.

use ./lib/config.nu
use ./lib/complete.nu
use ./lib/query.nu

# Open the saved-query directory (or a specific query file) in $EDITOR.
#
# With no argument, opens the query directory itself. With a file, opens that
# file (a path relative to the query dir); tab-completion lists existing saved
# queries. The editor is launched with the query dir as its working directory.
@category mole
@example "open the query directory in \$EDITOR" { mole query edit }
@example "open a specific saved query" { mole query edit "reports/daily.sql" }
export def "query edit" [
  queryfile?: string@"complete queryfile"   # Saved query to open, relative to the query dir; omit to open the dir itself
]: nothing -> nothing {
  let d = config querydir
  mkdir $d   # ensure the query dir exists so `cd` below can't fail on first use
  let target = if ($queryfile | is-not-empty) { [$d $queryfile] | path join } else { $d }
  # `$EDITOR` may carry flags (e.g. "code -w"); split them off the command name.
  let ed = ($env.EDITOR? | default "vi" | split row " " | where {|w| $w != "" })
  let cmd = ($ed | first)
  let flags = ($ed | skip 1)
  # Run the editor WITH the query dir as its working directory. `cd` is scoped to
  # this command (query edit is not `--env`), so it sets the launched editor's cwd
  # without changing the caller's dir. We launch the editor DIRECTLY (no `nu -c`
  # subprocess / string interpolation, which mangled cwd/quoting).
  cd $d
  # For vim-family editors, also pin the working dir from inside the editor: a late
  # `VimEnter` autocmd runs after the user's own config autocmds, so the query dir
  # sticks even if a plugin would otherwise reset the cwd (e.g. to $HOME) on startup.
  if (($cmd | path basename) in ["nvim" "vim" "gvim" "mvim" "vi" "view"]) {
    ^$cmd ...$flags -c $"autocmd VimEnter * cd ($d)" $target
  } else {
    ^$cmd ...$flags $target
  }
}

# Print the text of a saved query.
#
# Reads the saved query (a path relative to the query dir) as raw text and
# returns it; tab-completion lists existing saved queries.
@category mole
@example "show a saved query" { mole query show "reports/daily.sql" }
export def "query show" [
  queryfile: string@"complete queryfile"   # Saved query to print, relative to the query dir
]: nothing -> string {
  query resolve --file $queryfile
}

# Absolute path to the saved-query directory (~/.config/mole/queries).
@category mole
@example "print the query directory path" { mole query dir }
export def "query dir" []: nothing -> string { config querydir }

export use ./cfg.nu
