# mole-zellij — a user-facing package (like mole-mermaid / mole-sqls) that stands
# up a per-database DEVELOPMENT ENVIRONMENT inside an existing zellij session.
#
# For one connection it: (1) renders the schema to an image and opens it (via
# mole-mermaid), and (2) opens a zellij TAB running the `mole` layout — a
# full-window editor with a floating, focused query REPL on top — in the project
# directory, with the connection already activated.
#
# LAYOUTS — the `zz` way. This package does NOT generate KDL on the fly. It ships a
# real layout FILE (./layouts/mole.kdl) that `install` copies into
# ~/.config/zellij/layouts/, so it becomes part of your zellij config: editable,
# reusable (`zz tab mole`), and sharing the same tab-bar / status-bar / swap-layout
# chrome as every other tab. `dev` then opens it BY NAME, exactly like zz's
# `apply-layout`: `zellij action new-tab --cwd <dir> --layout mole --name <conn>`
# then `rename-tab` (the layout's own `tab name=` otherwise wins over --name).
#
# The layout is the tiled editor only. The FLOATING, focused query pane is created
# imperatively after the tab opens — `zellij action new-tab --layout` does NOT
# honour layout-embedded floating panes, so `dev` runs `zellij run --floating … --
# nu --execute 'mole-zellij enter'` (a run-floating pane opens focused). The layout
# is connection-AGNOSTIC; the dynamic part is a tiny marker file: `dev` records
# `{driver, connection}` via mole's cache and `enter` reads it back to set
# $env.MOLE_CURRENT — so `mole-<driver> select …` works with no --connection. (A
# fresh REPL sources your config, which already `use`s your drivers, so enter only
# has to flip the current pointer.)
#
# LAYERING (see [[mole-layering-rule]]). Almost standalone: it imports only
# mole/lib/conn.nu (connection NAME → driver, cross-driver completion) and
# mole/lib/cache.nu (the marker). It never imports a SQL driver or mole-mermaid at
# the Nushell level — it composes them as command strings run by a child `nu` (the
# schema render). Not a driver → no export-env / conn register.

use mole/lib/conn.nu
use mole/lib/cache.nu
use mole/lib/config.nu

# This package's own directory, captured at parse time (`path self` is parse-only),
# so `install` can find the shipped ./layouts/mole.kdl regardless of cwd.
const HERE = (path self | path dirname)

# ---- layout asset + install target -------------------------------------------

# Absolute path to the layout file shipped inside this package.
def "asset-layout" []: nothing -> string { [$HERE "layouts" "mole.kdl"] | path join }

# The workspace root — the parent of this package, which also contains mole/,
# mole-<driver>/ and mole-mermaid/. Passed as the child `nu`'s NU_LIB_DIRS when
# rendering the schema, so it resolves those modules even though NU_LIB_DIRS does
# not survive an `^nu` spawn (verified: a single dir here covers the whole graph).
def "workspace-dir" []: nothing -> string { $HERE | path dirname }

# The user's zellij layouts directory (honours $XDG_CONFIG_HOME).
def "layouts-dir" []: nothing -> string {
  ($env.XDG_CONFIG_HOME? | default ($env.HOME | path join ".config")) | path join "zellij" "layouts"
}

# Where the `mole` layout is (or will be) installed.
def "installed-layout" []: nothing -> string { layouts-dir | path join "mole.kdl" }

# Sync the shipped layout into the zellij layouts dir: install it when missing, and
# REFRESH it when an out-of-date copy is present (an older mole-zellij shipped a
# layout that embedded the query pane — leaving it stale is what produced duplicate
# panes). It is a managed file; `dev` keeps it identical to the shipped version.
def "ensure-installed" []: nothing -> string {
  let dest = (installed-layout)
  let stale = (not ($dest | path exists)) or ((open --raw $dest) != (open --raw (asset-layout)))
  if $stale {
    mkdir (layouts-dir)
    cp (asset-layout) $dest
    print $"mole-zellij: synced layout → ($dest)"
  }
  $dest
}

# ---- presentation ------------------------------------------------------------

# A picker/banner prompt with the same accent style zz uses (colours resolve from
# the terminal palette, keeping it as the single source of truth).
def "styled-prompt" [text: string]: nothing -> string {
  $"(ansi yellow_bold)▸(ansi reset) (ansi blue_bold)($text)(ansi reset)"
}

# Fuzzy-pick a connection name across all drivers (used when `dev` gets no name).
def "pick-connection" []: nothing -> string {
  conn list | get -o name | default [] | input list --fuzzy (styled-prompt "mole connection") | default ""
}

# Cross-driver connection-name completer (mole-zellij spans every driver, unlike a
# driver plugin which scopes completion to its own).
def "complete-connection" []: nothing -> list<string> {
  conn list | get -o name | default []
}

# The marker file `dev` writes and `enter` reads.
def "marker-path" []: nothing -> string { cache path "zellij" "current" }

# ---- verbs -------------------------------------------------------------------

# Install the `mole` zellij layout into ~/.config/zellij/layouts/.
#
# `dev` syncs it automatically; run this to do so explicitly. It is a MANAGED file
# (`dev` keeps it identical to the shipped version): a plain `install` refreshes it
# when out of date and is a no-op when current; `--force` always rewrites it.
@category mole-zellij
@example "install / refresh the layout" { mole-zellij install }
@example "force a rewrite" { mole-zellij install --force }
export def "install" [
  --force   # rewrite even when already up to date
]: nothing -> string {
  let dest = (installed-layout)
  let current = ($dest | path exists) and ((open --raw $dest) == (open --raw (asset-layout)))
  if $current and (not $force) {
    print $"mole-zellij: layout up to date at ($dest)"
    return $dest
  }
  mkdir (layouts-dir)
  cp (asset-layout) $dest
  print $"mole-zellij: installed layout → ($dest)"
  $dest
}

# Stand up a development environment for a database connection.
#
# Renders the connection's schema and opens it (via mole-mermaid). By default a dark
# VECTOR PDF opened in the native viewer (Preview) — it zooms far past a browser's
# limit, ideal for a big schema. `--format` also takes html (dark pan/zoom page in a
# browser) | svg | png. Then it opens a zellij tab running the `mole` layout — a
# full-window editor with a single 90×90 floating, focused query REPL — rooted at
# `--dir` (default: the mole QUERY directory, so the editor lands on your saved .sql
# queries), with the connection activated. Omit the
# connection to pick one with a fuzzy finder. Must be run from INSIDE a zellij
# session (it adds a tab to the current one).
#
# The schema render is BEST-EFFORT (skipped with a note if the driver has no schema
# or Docker/mermaid is unavailable); `--no-schema` skips it, `--dry-run` returns the
# plan without touching zellij or the filesystem.
@category mole-zellij
@example "open a dev tab for the 'app' connection in the current dir" {
  mole-zellij dev app
}
@example "pick a connection, point the editor at a project, render a PNG schema" {
  mole-zellij dev --dir ~/work/app --format png
}
@example "inspect the plan without launching" {
  mole-zellij dev app --dry-run
}
export def "dev" [
  connection?: string@complete-connection   # a mole connection (any driver); omit to fuzzy-pick
  --dir(-d): path                            # directory the tab opens in — editor + query REPL (default: the mole query dir)
  --format(-f): string = "pdf"              # schema format: pdf (dark vector, opens in Preview, default) | html (dark browser pan/zoom) | svg | png
  --no-schema                               # don't render/open the schema diagram
  --dry-run                                 # return the plan instead of launching (no side effects)
]: nothing -> any {
  let conn = (if ($connection | is-empty) { pick-connection } else { $connection })
  if ($conn | is-empty) { return }

  let conf = (conn resolve $conn)   # errors on an unknown connection
  let driver = $conf.driver
  let module = $"mole-($driver)"
  # Default the tab's working dir to the mole QUERY dir, so the editor opens on your
  # saved .sql queries (not wherever `dev` was launched). `--dir` overrides it.
  let d = ($dir | default (config querydir) | path expand)
  # pdf default: mole-mermaid renders a dark VECTOR pdf (svg → rsvg-convert) that
  # opens in Preview and zooms far past a browser. (html gives a dark browser
  # pan/zoom page; svg/png are artefacts.)
  let schema_cmd = $"use ($module); use mole-mermaid; ($module) schema --full -c ($conn) | mole-mermaid er-schema | mole-mermaid render -f ($format)"
  let plan = {
    connection: $conn
    driver: $driver
    module: $module
    dir: $d
    layout: "mole"
    layout_path: (installed-layout)
    marker: (marker-path)
    schema_cmd: $schema_cmd
  }
  if $dry_run { return $plan }

  if ($env.ZELLIJ? | is-empty) {
    print "mole-zellij: not inside a zellij session — run this from inside zellij (it opens a new tab)"
    return
  }

  ensure-installed
  # Record the choice so the layout's floating query pane (`mole-zellij enter`) can activate it.
  {driver: $driver, connection: $conn} | cache write (marker-path)

  # Open the tab from the installed layout — a tiled nvim editor plus the single
  # 90×90 floating query pane the layout defines (which also blocks the session's
  # inherited scratch float). The layout's own `tab name="mole"` wins over --name, so
  # rename explicitly (per zz). (`| ignore` drops the tab-id echoed to stdout.)
  ^zellij action new-tab --cwd $d --layout "mole" --name $conn | ignore
  ^zellij action rename-tab $conn | ignore

  # Render + open the (Docker-backed, potentially slow) schema image, best-effort.
  #    NU_LIB_DIRS doesn't survive an `^nu` spawn, so pass the workspace root
  #    explicitly and skip config loading — the child resolves the driver + mermaid
  #    modules from that one dir.
  if not $no_schema {
    try {
      with-env {NU_LIB_DIRS: (workspace-dir)} { ^nu --no-config-file -c $schema_cmd }
    } catch {|e| print $"mole-zellij: schema render skipped — ($e.msg)" }
  }
}

# Activate the connection `dev` recorded, in the current REPL. (Layout hook.)
#
# The floating query pane `dev` spawns runs this: it reads the marker `dev` wrote and
# sets $env.MOLE_CURRENT for that driver, so `mole-<driver> …` verbs resolve the
# connection with no --connection flag. Being `--env`, the change persists in the
# pane's shell. Run manually to re-activate the last connection in another shell.
# No-op (no error) when no connection has been recorded yet.
@category mole-zellij
@example "re-activate the last dev'd connection here" { mole-zellij enter }
export def --env "enter" []: nothing -> nothing {
  let m = (cache read (marker-path))
  if ($m | is-empty) { return }
  $env.MOLE_CURRENT = (($env.MOLE_CURRENT? | default {}) | upsert $m.driver $m.connection)
  let loaded = (scope commands | get name | any {|n| $n | str starts-with $"mole-($m.driver) " })
  let hint = if $loaded { "" } else { $"  (ansi yellow)· run: use mole-($m.driver)(ansi reset)" }
  print $"(ansi green_bold)▸(ansi reset) (ansi blue_bold)($m.driver)(ansi reset) · ($m.connection) active($hint)"
}
