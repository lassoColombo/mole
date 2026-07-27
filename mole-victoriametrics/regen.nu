#!/usr/bin/env nu
# Regenerate client.nu for VictoriaMetrics (single-node).
#
# SPEC STRATEGY — vendor Prometheus's OpenAPI 3.1 spec. VictoriaMetrics does NOT
# ship its own OpenAPI spec, but it is Prometheus-querying-API compatible: it
# serves the SAME `/api/v1/{query,query_range,series,labels,label/{name}/values,
# metadata}` handlers with the SAME request params and response envelopes. So we
# generate the shared surface from `openapi/prometheus-3.1.yaml` (a copy of
# mole-prometheus's vendored spec) exactly as mole-prometheus does, then HAND-
# APPEND the two VictoriaMetrics-specific read endpoints the spec can't describe:
#   - GET /api/v1/status/tsdb  — TSDB cardinality stats
#   - GET /api/v1/export       — raw sample dump as JSON lines
#
# WORKFLOW — generate, trim, relax, append (re-run whenever the vendored spec moves):
#   1. Run nu-http-client-generator over the spec, keeping only GET operations
#      tagged query/series/labels/metadata (structurally read-only).
#   2. Trim to the exact endpoints the wrapper uses — the tag filter also pulls in
#      a few extra query/label operations and their enum completers; drop those.
#   3. Relax each command's `-> record<status: ...>` return type to `-> any`. The
#      API omits `warnings`/`infos` on ordinary responses, and Nushell RUNTIME-
#      ENFORCES declared output types, so the precise generated type would reject
#      nearly every real response. The wrapper (mod.nu) does the real typing.
#   4. Append the VM-specific GETs, reusing the generated request helpers.
#
# To adopt a newer Prometheus spec, refresh openapi/prometheus-3.1.yaml first
# (e.g. `curl -s "http://<prometheus>/api/v1/openapi.yaml?openapi_version=3.1"`),
# then re-run `nu regen.nu`.
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

# VM-specific GET endpoints appended verbatim after the generated client. They
# reuse the generated helpers (build-auth, build-url, serialize-qp, send-get), so
# they must match the generator's calling conventions. Kept here (not hand-edited
# into client.nu) so a regen never wipes them. Both are read-only.
const VM_EXTRA = '

# ---- VictoriaMetrics-specific read endpoints (hand-appended by regen.nu) -------
# Not in the Prometheus OpenAPI spec; VM-only. Reuse the generated request stack.

# TSDB status / cardinality stats
#
# GET /status/tsdb
export def "status-tsdb get" [
  --base-url(-b): string@base-url-completer # API base URL
  --token(-t): string # Auth token
  --auth-scheme(-a): string@auth-scheme-completer # Auth scheme
  --insecure(-k) # Skip TLS verification
  --max-time(-m): duration # Timeout
  --raw(-r) # Fetch as text
  --allow-errors(-e) # Return full response without error handling
  --full(-F) # Return full response record {status, headers, body} while still raising on 4xx/5xx
  --dry-run(-n) # Return the request that would be sent without executing it
  --date: string # Day (YYYY-MM-DD) to report stats for. Optional; defaults to all time.
  --topN: int # Number of top entries to return per stat. Optional.
  --match: list<string> # Series selector(s) to scope the stats. Optional.
]: nothing -> any {
  let auth = (build-auth $token ($auth_scheme | default "bearer"))
  let base = ($base_url | default $BASE_URL)
  let qp = [(serialize-qp "date" $date "scalar") (serialize-qp "topN" $topN "scalar") (serialize-qp "match[]" $match "csv")] | flatten | str join "&"
  let full_url = (build-url $base "/status/tsdb" $qp $auth.query)
  let accept_val = "application/json"
  let auth = ($auth | update headers ($auth.headers | merge {Accept: $accept_val}))
  let req = {
    method: "get"
    url: $full_url
    query: ({"date": $date, "topN": $topN, "match[]": $match} | compact)
    headers: $auth.headers
    body: null
    content_type: null
    timeout: ($max_time | default 30min)
    auth: {scheme: $auth.scheme, location: $auth.location}
  }
  if $dry_run { return ({dry_run: true} | merge $req) }
  send-get $req $insecure $raw $allow_errors $full [200]
}

# Export raw samples as JSON lines
#
# GET /export
# Returns newline-delimited JSON objects (one series per line), NOT the
# {status, data} envelope. The wrapper fetches --raw and parses the JSONL.
export def "export get" [
  --base-url(-b): string@base-url-completer # API base URL
  --token(-t): string # Auth token
  --auth-scheme(-a): string@auth-scheme-completer # Auth scheme
  --insecure(-k) # Skip TLS verification
  --max-time(-m): duration # Timeout
  --raw(-r) # Fetch as text
  --allow-errors(-e) # Return full response without error handling
  --full(-F) # Return full response record {status, headers, body} while still raising on 4xx/5xx
  --dry-run(-n) # Return the request that would be sent without executing it
  --match: list<string> # Series selector(s) to export. Required by VM.
  --start: string # Start timestamp. Optional.
  --end: string # End timestamp. Optional.
  --max-rows-per-line: int # Max samples per JSON line. Optional.
  --reduce-mem-usage: string # "1" to reduce memory usage for large exports. Optional.
]: nothing -> any {
  let auth = (build-auth $token ($auth_scheme | default "bearer"))
  let base = ($base_url | default $BASE_URL)
  let qp = [(serialize-qp "match[]" $match "csv") (serialize-qp "start" $start "scalar") (serialize-qp "end" $end "scalar") (serialize-qp "max_rows_per_line" $max_rows_per_line "scalar") (serialize-qp "reduce_mem_usage" $reduce_mem_usage "scalar")] | flatten | str join "&"
  let full_url = (build-url $base "/export" $qp $auth.query)
  let accept_val = "application/json"
  let auth = ($auth | update headers ($auth.headers | merge {Accept: $accept_val}))
  let req = {
    method: "get"
    url: $full_url
    query: ({"match[]": $match, "start": $start, "end": $end, "max_rows_per_line": $max_rows_per_line, "reduce_mem_usage": $reduce_mem_usage} | compact)
    headers: $auth.headers
    body: null
    content_type: null
    timeout: ($max_time | default 30min)
    auth: {scheme: $auth.scheme, location: $auth.location}
  }
  if $dry_run { return ({dry_run: true} | merge $req) }
  send-get $req $insecure $raw $allow_errors $full [200]
}
'

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
    '--name victoriametrics'
    '--no-introspection'
    '--default-base-url "http://localhost:8428/api/v1"'
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
  let relaxed = ($kept
    | str join "\n\n"
    | str replace --all --regex '(?m)-> record<status:.*> \{$' '-> any {')

  # Append the hand-written VM-specific GET endpoints.
  let final = ($relaxed ++ $VM_EXTRA)

  $final | save -f $out
  rm -f $tmp
  let n = ($final | parse --regex '(?m)^export def "(?<name>[^"]+)"' | length)
  print $"regenerated ($out) — ($n) commands"
}
