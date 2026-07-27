# mole-victorialogs/client — HAND-WRITTEN low-level HTTP client for the
# VictoriaLogs select API.
#
# WHY HAND-WRITTEN (not generated like mole-prometheus/client.nu): VictoriaLogs
# ships NO OpenAPI/Swagger spec (verified — only prose docs at
# https://docs.victoriametrics.com/victorialogs/querying/).
# So there is no `openapi/` dir and no `regen.nu`; this thin request/parse layer is the
# client.
#
# One thin function per endpoint. Each takes a resolved connection record plus
# endpoint params, performs the POST, and returns lightly-parsed data: the raw
# JSON-lines TEXT for `query` (the wrapper's pure transforms parse it), and the
# `from json` record for every other endpoint. NO completion, NO time-range
# sugar, NO typing beyond `from json` — that all lives in mod.nu, so this layer
# stays mechanical and swappable.
#
# Read-only is structural: every endpoint is under `/select/logsql/` and only
# reads, so there is no danger prompt. API reference:
# https://docs.victoriametrics.com/victorialogs/querying/

# Default per-request timeout. Analytics queries can be slow on large datasets.
const DEFAULT_TIMEOUT = 60sec

# Base URL for a connection: explicit `url`, else host/port, else localhost:9428.
# A trailing slash on `url` is trimmed so path joins stay clean.
export def "base-url" [conf: record]: nothing -> string {
  let u = ($conf | get -o url)
  if ($u | is-not-empty) { return ($u | str trim --right --char '/') }
  let host = ($conf | get -o host | default "localhost")
  let port = ($conf | get -o port | default 9428)
  $"http://($host):($port)"
}

# Request headers: multi-tenancy (AccountID/ProjectID) plus auth. A bearer token
# (`token`/`bearerToken`) wins over basic auth (`user`/`password`) when both are
# configured. All values coerced to string — `http --headers` silently drops
# non-string values.
export def "headers" [conf: record]: nothing -> record {
  mut h = {}
  let acct = ($conf | get -o accountID)
  if ($acct | is-not-empty) { $h = ($h | insert AccountID ($acct | into string)) }
  let proj = ($conf | get -o projectID)
  if ($proj | is-not-empty) { $h = ($h | insert ProjectID ($proj | into string)) }
  let token = ($conf | get -o token | default ($conf | get -o bearerToken))
  if ($token | is-not-empty) {
    $h | insert Authorization $"Bearer ($token)"
  } else {
    let user = ($conf | get -o user)
    if ($user | is-not-empty) {
      let pw = ($conf | get -o password | default "")
      $h | insert Authorization ("Basic " + ($"($user):($pw)" | encode base64))
    } else {
      $h
    }
  }
}

# POST a form-urlencoded request to <path>, returning the raw response body as
# text. Params with null/empty values are dropped; the rest are stringified and
# handed to `http post` as a record, which form-encodes them. Raises on non-2xx
# with the server's error body. `--timeout` overrides the default (completers
# pass a short one). `--insecure` from the connection skips TLS verification.
export def "request" [conf: record, path: string, params: record, --timeout: duration]: nothing -> string {
  let url = $"(base-url $conf)($path)"
  let form = (
    $params
    | items {|k, v| {k: $k, v: $v} }
    | where {|it| $it.v | is-not-empty }
    | reduce --fold {} {|it, acc| $acc | insert $it.k ($it.v | into string) }
  )
  let insecure = ($conf | get -o insecure | default false)
  let resp = (
    http post
      --content-type "application/x-www-form-urlencoded"
      --headers (headers $conf)
      --max-time ($timeout | default $DEFAULT_TIMEOUT)
      --full --allow-errors --raw
      --insecure=$insecure
      $url $form
  )
  if ($resp.status < 200) or ($resp.status >= 300) {
    error make --unspanned {msg: $"VictoriaLogs HTTP ($resp.status) at ($path): ($resp.body)"}
  }
  $resp.body
}

# ---- endpoints ---------------------------------------------------------------
# `query` returns the raw JSON-lines TEXT (the wrapper parses it); every other
# endpoint returns the `from json` record for the wrapper's pure transforms.

# Run a LogsQL query. Returns the raw JSON-lines body text.
export def "query" [
  conf: record
  query: string
  --start: string
  --end: string
  --limit: int
  --offset: int
] {
  request $conf "/select/logsql/query" { query: $query, start: $start, end: $end, limit: $limit, offset: $offset }
}

# Per-bucket hit counts over time. Returns the `{hits: [...]}` record.
export def "hits" [
  conf: record
  query: string
  --start: string
  --end: string
  --step: string
  --field: string
  --offset: string
] {
  request $conf "/select/logsql/hits" {
    query: $query, start: $start, end: $end, step: $step, field: $field, offset: $offset
  } | from json
}

# Instant stats query (the LogsQL must contain a `| stats` pipe). Returns the
# Prometheus-shaped `{status, data: {resultType, result}}` record.
export def "stats-query" [
  conf: record
  query: string
  --time: string
] {
  request $conf "/select/logsql/stats_query" { query: $query, time: $time } | from json
}

# Range stats query. Returns the Prometheus-shaped `{status, data}` record.
export def "stats-query-range" [
  conf: record
  query: string
  --start: string
  --end: string
  --step: string
] {
  request $conf "/select/logsql/stats_query_range" {
    query: $query, start: $start, end: $end, step: $step
  } | from json
}

# Field names present in the query results. Returns the `{values: [...]}` record.
export def "field-names" [
  conf: record
  query: string
  --start: string
  --end: string
] {
  request $conf "/select/logsql/field_names" { query: $query, start: $start, end: $end } | from json
}

# Distinct values of <field> in the query results. Returns `{values: [...]}`.
export def "field-values" [
  conf: record
  query: string
  field: string
  --start: string
  --end: string
  --limit: int
  --timeout: duration
] {
  request $conf "/select/logsql/field_values" {
    query: $query, field: $field, start: $start, end: $end, limit: $limit
  } --timeout $timeout | from json
}

# Stream label names present in the query results. Returns `{values: [...]}`.
export def "stream-field-names" [
  conf: record
  query: string
  --start: string
  --end: string
] {
  request $conf "/select/logsql/stream_field_names" { query: $query, start: $start, end: $end } | from json
}

# Distinct values of stream label <field>. Returns `{values: [...]}`.
export def "stream-field-values" [
  conf: record
  query: string
  field: string
  --start: string
  --end: string
  --limit: int
] {
  request $conf "/select/logsql/stream_field_values" {
    query: $query, field: $field, start: $start, end: $end, limit: $limit
  } | from json
}

# Active streams matching the query, with hit counts. Returns `{values: [...]}`,
# each `value` a stream selector like `{host="h1",app="foo"}`.
export def "streams" [
  conf: record
  query: string
  --start: string
  --end: string
  --limit: int
] {
  request $conf "/select/logsql/streams" { query: $query, start: $start, end: $end, limit: $limit } | from json
}

# Stream ids matching the query, with hit counts. Returns `{values: [...]}`.
export def "stream-ids" [
  conf: record
  query: string
  --start: string
  --end: string
  --limit: int
] {
  request $conf "/select/logsql/stream_ids" { query: $query, start: $start, end: $end, limit: $limit } | from json
}

# Most frequent field values grouped by field. Returns the `{facets: [...]}` record.
export def "facets" [
  conf: record
  query: string
  --start: string
  --end: string
  --limit: int
] {
  request $conf "/select/logsql/facets" { query: $query, start: $start, end: $end, limit: $limit } | from json
}
