# mole — the standalone core module for the mole ecosystem.
#
# ARCHITECTURE (see DESIGN.md). mole is a foundation that source submodules
# depend on, never the other way around. mole never imports, enumerates, or
# generates anything about submodules — installing one is only cloning a sibling
# repo. No umbrella, no `sync`/codegen step. Import rule everywhere: `use module`,
# never `use module *`.
#
# This file COMPOSES the user-facing `mole` module from:
#   - ./cfg.nu         → `mole cfg show/file/querydir/edit`
#   - ./submodules.nu  → `mole submodules sources/doctor/install`
#   - two root commands below (`mole api-version`, `mole edit`)
# and nothing more. The PLUMBING lives in ./lib/* and is imported PRIVATELY here
# (and directly by submodules via `use ../mole/lib/<concern>`), so `use mole`
# exposes only management commands — never the plumbing.

use ./lib/version.nu
use ./lib/config.nu
use ./lib/complete.nu

# The core<->submodule contract version this mole provides.
#
# Every submodule declares the api version it targets in its `mole.nuon`;
# `mole submodules doctor` checks each declared target against this value using
# native semver. The version is stored in mole.nuon and read at runtime — bump
# it there, not in code.
@category mole
@example "show the contract version this mole provides" { api-version } --result "1.0.0"
export def "api-version" []: nothing -> string { version api-version }

# Open the saved-query directory (or a specific query file) in $EDITOR.
#
# With no argument, opens the query directory itself. With a file, opens that
# file (a path relative to the query dir); tab-completion lists existing saved
# queries. The editor is launched with the query dir as its working directory.
@category mole
@example "open the query directory in \$EDITOR" { edit }
@example "open a specific saved query" { edit "reports/daily.sql" }
export def "edit" [
  queryfile?: string@"complete queryfile"   # Saved query to open, relative to the query dir; omit to open the dir itself
]: nothing -> nothing {
  let d = config querydir
  let target = if ($queryfile | is-not-empty) { [$d $queryfile] | path join } else { $d }
  nu -c $"cd ($d); ($env.EDITOR) ($target)"
}

export use ./cfg.nu
export use ./submodules.nu
