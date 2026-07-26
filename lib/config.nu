# mole/lib/config — config + query-dir paths (XDG-aware).
# Import individually: `use ../mole/lib/config` → `config file`, `config querydir`.

# The mole config directory, honoring $env.XDG_CONFIG_HOME.
#
# Returns `$XDG_CONFIG_HOME/mole` when that env var is set, else `~/.config/mole`.
@category mole-lib
@example "the config root directory" { config-dir }
def config-dir []: nothing -> string {
  let xdg = $env.XDG_CONFIG_HOME? | default ""
  let base = if ($xdg | is-not-empty) { $xdg } else { [$nu.home-path .config] | path join }
  [$base mole] | path join
}

# Absolute path to the connections file (`<config-dir>/connections.yaml`).
@category mole-lib
@example "the connections file path" { file }
export def "file" []: nothing -> string { [(config-dir) connections.yaml] | path join }

# Absolute path to the saved-query directory (`<config-dir>/queries`).
@category mole-lib
@example "the query directory path" { querydir }
export def "querydir" []: nothing -> string { [(config-dir) queries] | path join }
