# mole/submodules.nu — discovery, health, and install of source submodules.
# Composed by mod.nu as `mole submodules …`. Leaf def names; `export use
# ./submodules.nu` prefixes them with `submodules`.

use ./lib/version.nu

# Self-locate. HERE = the core module dir (mole/); WORKSPACE = where sibling
# submodules live (mole-*). `path self` is const-only, so derive at parse time.
const HERE = (path self | path dirname)
const WORKSPACE = ($HERE | path dirname)

# ---- requirement helpers ------------------------------------------------------

# Normalize a `requires` entry to {name, want}. An entry is a record
# {name, version?} whose `version` is the semver RANGE of the CLI the module
# supports (default "*" = any). A legacy bare-string entry ("psql") → want "*".
def req-parts [r: any]: nothing -> record {
  if ($r | describe | str starts-with "record") {
    { name: ($r.name | into string), want: ($r | get -o version | default "*") }
  } else {
    { name: ($r | into string), want: "*" }
  }
}

# Extract a semver (X.Y.Z) from a CLI's `--version` text. Picks the numeric token
# with the MOST dotted components, so a real X.Y.Z beats a 2-part path fragment
# (e.g. the `mysql@8.4` in a Homebrew keg path) or a frozen client tag (MariaDB's
# `15.1`, whose real server version `10.6.16` wins). A bare integer (Trino's
# `465`) becomes `465.0.0`. Ties resolve to the first token; null if none match.
def extract-cli-version [text: string]: nothing -> any {
  let toks = ($text | parse --regex '(?i)\bv?(?P<v>\d+(?:\.\d+){0,3})\b' | get -o v | default [])
  if ($toks | is-empty) { return null }
  let ranked = ($toks | each {|t| {t: $t, n: ($t | split row "." | length)} })
  let maxn = ($ranked | get n | math max)
  let best = ($ranked | where n == $maxn | first | get t)
  (($best | split row ".") ++ ["0" "0"] | first 3 | str join ".")
}

# The installed version of a CLI on PATH as X.Y.Z, or null if absent/unparseable.
# Runs `<name> --version` and parses it losslessly (see `extract-cli-version`).
def cli-version [name: string]: nothing -> any {
  if (which $name | is-empty) { return null }
  let r = (try { ^$name --version | complete } catch { null })
  if $r == null { return null }
  extract-cli-version $"($r | get -o stdout | default '')\n($r | get -o stderr | default '')"
}

# Discover installed submodules (plugins AND libraries) by their manifests.
#
# Reads pure data on disk at runtime, independent of what has been `use`d: every
# `<workspace>/mole-*/mole.nuon` manifest, each row enriched with its `dir` (the
# submodule directory basename). A manifest's `kind` field distinguishes a
# plugin (data source) from a library.
@example "list installed submodule manifests" { discover }
def discover []: nothing -> table {
  glob ([$WORKSPACE "mole-*" "mole.nuon"] | path join)
  | each {|f| open $f | insert dir ($f | path dirname | path basename) }
}

# Completer: installed submodule directory names (mole-*).
@example "installed directory names" { installed-names } --result ["mole-sql", "mole-vlogs"]
def installed-names []: nothing -> list<string> { discover | get dir }

# Completer: valid native-semver release tags of the submodule named on the
# command line.
#
# Context-aware: parses the submodule name out of the `checkout <name>` line
# typed so far, then lists that repo's git tags. Tags with a `v` prefix or that
# are not native semver are ignored; latest first.
@example "tags available for the submodule on the command line" { submodule-tags "mole submodules checkout mole-sql " }
def submodule-tags [
  context: string   # The command line typed so far, up to the cursor (supplied by the completer)
]: nothing -> list<string> {
  let name = ($context | parse --regex 'checkout\s+(?P<n>[^\s]+)' | get -o 0.n)
  if ($name | is-empty) { return [] }
  let dir = [$WORKSPACE $name] | path join
  if not ($dir | path exists) { return [] }
  let r = (^git -C $dir tag | complete)
  if $r.exit_code != 0 { return [] }
  $r.stdout | lines
  | where {|t| ($t | str trim) != "" }
  | where {|t| try { $t | into semver; true } catch { false } }
  | sort-by {|t| $t | into semver }
  | reverse
}

# Installed data sources (plugins only), with load and readiness status.
#
# One row per installed plugin submodule, reporting: `loaded` (its manifest is
# in the self-assembled `$env.MOLE_REGISTRY`, i.e. the submodule has been `use`d)
# and `ready` (all of its required external CLIs are on PATH). Libraries are not
# data sources; use `mole submodules list` to see everything installed.
@category mole
@example "list data sources and their status" { sources }
export def "sources" []: nothing -> table {
  let loaded = ($env.MOLE_REGISTRY? | default {} | columns)
  discover
  | where {|m| ($m | get -o kind | default "plugin") == "plugin" }
  | each {|m|
    {
      source: $m.source
      version: ($m | get -o version | default "?")
      api: ($m | get -o api | default "?")
      drivers: ($m | get -o drivers | default [] | str join ", ")
      loaded: ($m.source in $loaded)
      ready: (($m | get -o requires | default []) | all {|r| which (req-parts $r | get name) | is-not-empty })
      summary: ($m | get -o summary | default "")
    }
  }
}

# Everything installed (plugins and libraries).
#
# One row per installed submodule with its `kind` (plugin or library),
# `version`, the mole-core `api` it targets, declared library `deps`, and a
# `summary`. Unlike `sources`, this includes libraries and does not check load
# or readiness status.
@category mole
@example "list all installed submodules" { list }
export def "list" []: nothing -> table {
  discover | each {|m|
    {
      module: $m.dir
      kind: ($m | get -o kind | default "plugin")
      version: ($m | get -o version | default "?")
      api: ($m | get -o api | default "?")
      deps: ($m | get -o deps | default [])
      summary: ($m | get -o summary | default "")
    }
  }
}

# Environment health check, one row per installed module (plugin or library).
#
# Checks all three declared requirement kinds, each a native semver-range:
#   api_ok — the mole-core api the module requires, satisfied by this mole
#            (null when the requirement is FREE: `*` or absent, e.g. a pure lib)
#   deps   — per module dependency: present and version in range
#            ({module, want, got, ok})
#   clis   — per required executable: on PATH and its `--version` in range
#            ({cli, want, got, ok}); got is the detected X.Y.Z (null if absent or
#            unparseable), ok is false when missing, null when present-but-
#            unparseable, else the range test
# Ranges: a bare version means caret (`0.1.0` ≡ `^0.1.0`); `^`/`~`/`>=`/`=`, a
# comma-compound (`>=1.0.0, <2.0.0`) or `*` are honored. CLI versions are probed
# by running `<cli> --version` (see `cli-version`).
@category mole
@example "check submodule/environment health" { doctor }
export def "doctor" []: nothing -> table {
  let core = version api-version
  let installed = discover
  let by_dir = ($installed | reduce --fold {} {|m, acc| $acc | upsert $m.dir $m })
  $installed | each {|m|
    let api = ($m | get -o api)
    # api requirement on core; `*` or absent = free (e.g. a pure library).
    let api_ok = if ($api | is-empty) or ($api == "*") { null } else {
      try { ($core | into semver) in ($api | into semver-range) } catch { false }
    }
    let deps = ($m | get -o deps | default [] | each {|d|
      let got = ($by_dir | get -o $d.module)
      let ok = if ($got | is-empty) { false } else {
        try { ($got.version | into semver) in ($d.version | into semver-range) } catch { false }
      }
      { module: $d.module, want: $d.version, got: ($got | get -o version | default null), ok: $ok }
    })
    # executable requirements: on PATH AND detected version within the range.
    let clis = ($m | get -o requires | default [] | each {|r|
      let rp = (req-parts $r)
      let present = (which $rp.name | is-not-empty)
      let got = if $present { cli-version $rp.name } else { null }
      let ok = if not $present { false } else if ($rp.want == "*") { true } else if ($got | is-empty) { null } else {
        try { ($got | into semver) in ($rp.want | into semver-range) } catch { false }
      }
      { cli: $rp.name, want: $rp.want, got: $got, ok: $ok }
    })
    {
      module: $m.dir
      kind: ($m | get -o kind | default "plugin")
      api_target: ($api | default "?")
      api_ok: $api_ok
      deps: $deps
      clis: $clis
    }
  }
}

# Install a submodule by cloning its repo as a sibling of mole.
#
# Clones `url` into `<workspace>/<name>`. Does NOT edit mole's source or wire the
# submodule up automatically — it only prints the `use` line to add to your
# config. Errors if `name` does not start with `mole-` or the destination
# already exists.
@category mole
@example "install the mole-sql submodule" { install mole-sql "https://example.com/mole-sql.git" }
export def "install" [
  name: string   # Submodule directory name; must start with `mole-`
  url: string    # Git URL to clone
]: nothing -> nothing {
  if not ($name | str starts-with "mole-") {
    error make {msg: $"submodule name must start with 'mole-' — got '($name)'"}
  }
  let dest = [$WORKSPACE $name] | path join
  if ($dest | path exists) { error make {msg: $"($dest) already exists"} }
  ^git clone $url $dest
  print $"installed ($name) at ($dest). Add `use ($name)` to your config to load it."
}

# Remove an installed submodule by deleting its sibling directory.
#
# Errors if the submodule is not installed. Does NOT touch your config — remember
# to drop its `use` line yourself.
@category mole
@example "uninstall a submodule" { uninstall mole-sql }
export def "uninstall" [
  name: string@installed-names   # Installed submodule directory name (tab-completes)
]: nothing -> nothing {
  let dir = [$WORKSPACE $name] | path join
  if not ($dir | path exists) { error make {msg: $"($name) is not installed"} }
  rm -rf $dir
  print $"uninstalled ($name). Remove `use ($name)` from your config."
}

# Update an installed submodule to the latest commit on its current branch.
#
# Runs a fast-forward-only `git pull` in the submodule directory. Errors if the
# submodule is not installed.
@category mole
@example "update a submodule to the latest commit" { update mole-sql }
export def "update" [
  name: string@installed-names   # Installed submodule directory name (tab-completes)
]: nothing -> nothing {
  let dir = [$WORKSPACE $name] | path join
  if not ($dir | path exists) { error make {msg: $"($name) is not installed"} }
  ^git -C $dir pull --ff-only
}

# Check out an installed submodule at a release tag.
#
# Tags must be native semver with no `v` prefix (e.g. `1.2.0`); tab-completion
# lists the submodule's available tags, latest first. Errors if the submodule is
# not installed or the tag is not native semver.
@category mole
@example "pin a submodule to a released version" { checkout mole-sql "1.2.0" }
export def "checkout" [
  name: string@installed-names   # Installed submodule directory name (tab-completes)
  tag: string@submodule-tags     # Native-semver release tag, no `v` prefix (tab-completes)
]: nothing -> nothing {
  let dir = [$WORKSPACE $name] | path join
  if not ($dir | path exists) { error make {msg: $"($name) is not installed"} }
  let valid = try { $tag | into semver; true } catch { false }
  if not $valid {
    error make {msg: $"tag must be a native-semver version with no 'v' prefix — got '($tag)'"}
  }
  ^git -C $dir checkout $tag
}
