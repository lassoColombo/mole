#!/usr/bin/env nu
# Regenerate client.nu from the vendored Alertmanager OpenAPI (Swagger 2.0) spec.
#
# WORKFLOW — generate, relax (re-run this whenever the vendored spec moves):
#   1. Run nu-http-client-generator over openapi/alertmanager-v2.yaml, keeping only
#      GET operations. `--methods [get]` is what makes this client READ-ONLY: the
#      spec's POST /silences, DELETE /silence/{id} and POST /alerts (the write
#      surface) are dropped by construction, so the module CANNOT mutate anything.
#      That leaves exactly the six read endpoints the wrapper wraps — status,
#      receivers, silences, silence/{id}, alerts, alerts/groups — so there is
#      nothing to trim (unlike mole-prometheus, whose tag filter over-selected).
#   2. Relax each command's precise `-> record<…>` / `-> table<…>` return type to
#      `-> any`. The API omits optional fields — a silence with no annotations, an
#      alert with no generatorURL, a cluster peer list that is absent when settling
#      — and Nushell RUNTIME-ENFORCES declared output types, so the precise
#      generated type rejects nearly every real response. The wrapper (mod.nu) does
#      the real typing (datetime coercion, etc.).
#
# Swagger 2.0 note: the generator handles Swagger 2.0. This spec's `basePath`
# (/api/v2/) is folded into the baked base URL below; array query params use
# `collectionFormat: multi` → the client's "multi" style (repeated key), correct
# for Alertmanager's `filter`/`receiver_matchers`.
#
# To adopt a newer API version, refresh the vendored spec first, then re-run:
#   curl -sSL "https://raw.githubusercontent.com/prometheus/alertmanager/main/api/v2/openapi.yaml" \
#     -o openapi/alertmanager-v2.yaml
#   nu regen.nu
#
# The generator lives outside NU_LIB_DIRS, so it is invoked in a subprocess by
# absolute path — `use $var` is a parse error, so it cannot be imported here.

const HERE = (path self | path dirname)

def main [
  --generator: path = "/Users/colombos/projects/personal/nushell/modules/nu-http-client-generator"  # generator module dir
  --spec: path   # override the vendored spec path
]: nothing -> nothing {
  let spec_path = ($spec | default ([$HERE openapi alertmanager-v2.yaml] | path join))
  let out = ([$HERE client.nu] | path join)
  if not ($spec_path | path exists) { error make {msg: $"spec not found: ($spec_path)"} }
  if not ($generator | path exists) { error make {msg: $"generator not found: ($generator)"} }

  # Generate the GET-only client to a temp file (subprocess, abs path).
  let tmp = (mktemp --suffix .nu)
  let gen = ([
    $'use "($generator)";'
    'nu-http-client-generator'
    $'"($spec_path)"'
    '--methods [get]'
    '--no-introspection'
    '--default-base-url "http://localhost:9093/api/v2"'
    $'-o "($tmp)"'
  ] | str join " ")
  let r = (^nu -c $gen | complete)
  if $r.exit_code != 0 { rm -f $tmp; error make {msg: $"generation failed:\n($r.stderr)"} }

  # Relax the precise response types to `any`. Only a command terminator is a line
  # that begins with `]: nothing -> record<` or `]: nothing -> table<` (the `]`
  # closes the multi-line parameter block). Helper defs keep their `[...]:` and
  # return type on a single line, so this anchor never touches them.
  let final = (open --raw $tmp
    | str replace --all --regex '(?m)^\]: nothing -> (?:record|table)<.*> \{$' ']: nothing -> any {')

  $final | save -f $out
  rm -f $tmp
  let n = ($final | parse --regex '(?m)^export def "(?<name>[^"]+)"' | length)
  print $"regenerated ($out) — ($n) commands"
}
