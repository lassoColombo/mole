#!/usr/bin/env nu
# Regenerate client.nu from the vendored Prometheus OpenAPI spec.
#
# WORKFLOW — generate, trim, relax (re-run this whenever the vendored spec moves):
#   1. Run nu-http-client-generator over openapi/prometheus-3.1.yaml, keeping only
#      GET operations tagged query/series/labels/metadata (structurally read-only).
#   2. Trim to the exact endpoints the wrapper uses — the tag filter also pulls in
#      a few extra query/label operations and their enum completers; drop those.
#   3. Relax each command's `-> record<status: ...>` return type to `-> any`.
#      Prometheus omits `warnings`/`infos` on ordinary responses, and Nushell
#      RUNTIME-ENFORCES declared output types, so the precise generated type would
#      reject nearly every real response. The wrapper (mod.nu) does the real typing.
#
# To adopt a newer API version, refresh the vendored spec first, then re-run:
#   curl -s "http://<prometheus>/api/v1/openapi.yaml?openapi_version=3.1" \
#     -o openapi/prometheus-3.1.yaml
#   nu regen.nu
#
# The generator lives outside NU_LIB_DIRS, so it is invoked in a subprocess by
# absolute path — `use $var` is a parse error, so it cannot be imported here.

const HERE = (path self | path dirname)

# Command blocks the tag filter includes but the wrapper does not use. Matched
# against the generated `export def "<name>"` header line, one block each.
const DROP_COMMANDS = [
  "query-exemplars list"
  "format-query list"
  "parse-query list"
  "search-metric-names list"
  "search-label-names list"
  "search-label-values list"
]

def main [
  --generator: path = "/Users/colombos/projects/personal/nushell/modules/nu-http-client-generator"  # generator module dir
  --spec: path   # override the vendored spec path
]: nothing -> nothing {
  let spec_path = ($spec | default ([$HERE openapi prometheus-3.1.yaml] | path join))
  let out = ([$HERE client.nu] | path join)
  if not ($spec_path | path exists) { error make {msg: $"spec not found: ($spec_path)"} }
  if not ($generator | path exists) { error make {msg: $"generator not found: ($generator)"} }

  # Generate the tag-filtered GET client to a temp file (subprocess, abs path).
  let tmp = (mktemp --suffix .nu)
  let gen = ([
    $'use "($generator)";'
    'nu-http-client-generator'
    $'"($spec_path)"'
    '--methods [get]'
    '--tags [query series labels metadata]'
    '--no-introspection'
    '--default-base-url "http://localhost:9090/api/v1"'
    $'-o "($tmp)"'
  ] | str join " ")
  let r = (^nu -c $gen | complete)
  if $r.exit_code != 0 { rm -f $tmp; error make {msg: $"generation failed:\n($r.stderr)"} }

  # Trim. Top-level items are blank-line separated, and each command's doc-comment
  # and `export def` share one block, so a per-block substring test suffices.
  let kept = (open --raw $tmp | split row "\n\n" | where {|b|
    let is_enum_completers = ($b | str contains "# Completers for enum parameters")
    let is_dropped_cmd = ($DROP_COMMANDS | any {|c| $b | str contains $'export def "($c)"' })
    not ($is_enum_completers or $is_dropped_cmd)
  })

  # Relax the response-envelope return type to `any`. Only command terminators
  # begin with `-> record<status:`; helper defs (bare `record`, `string`, …) are
  # left alone.
  let final = ($kept
    | str join "\n\n"
    | str replace --all --regex '(?m)-> record<status:.*> \{$' '-> any {')

  $final | save -f $out
  rm -f $tmp
  let n = ($final | parse --regex '(?m)^export def "(?<name>[^"]+)"' | length)
  print $"regenerated ($out) — ($n) commands"
}
