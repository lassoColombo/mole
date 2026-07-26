# mole/lib/version — the core<->submodule version contract.
# Import individually: `use ../mole/lib/version.nu` → `version api-version`, `version require-api`.

# mole's manifest lives at <mole>/mole.nuon (this file is <mole>/lib/version.nu).
const MANIFEST = (path self | path dirname | path dirname | path join "mole.nuon")

# The core<->submodule contract version, read at runtime from mole.nuon.
@category mole-lib
@example "the api version this mole provides" { api-version } --result "0.1.0"
export def "api-version" []: nothing -> string { open $MANIFEST | get api }

# Assert this mole satisfies the api version RANGE a submodule targets.
#
# Called by a submodule in its `export-env`. `wanted` is a native semver-range:
# a bare version means caret (`0.1.0` ≡ `^0.1.0`, cargo-style — compatible up to
# the next major), and `^` / `~` / `>=` / `=`, a comma-compound (`>=0.1.0, <0.3.0`)
# or `*` are all honored as written. A PURE module that imports nothing from core
# declares `*` — the requirement is then FREE (always satisfied). Errors when this
# mole's api version is outside the range. Uses Nushell-native semver.
@category mole-lib
@example "target the 0.1 core contract (bare = caret)" { require-api "0.1.0" }
@example "a pure module needs nothing from core — free" { require-api "*" }
export def "require-api" [
  wanted: string   # The api semver-range the submodule targets (bare version = caret; no `v` prefix)
]: nothing -> nothing {
  let ok = try { (api-version | into semver) in ($wanted | into semver-range) } catch { false }
  if not $ok {
    error make {msg: $"submodule targets mole api ($wanted), but mole provides (api-version)"}
  }
}
