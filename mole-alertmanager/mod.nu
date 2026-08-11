# mole-alertmanager — Prometheus Alertmanager driver plugin (READ-ONLY v2 API).
#
# A PLUGIN (data source): supports the `alertmanager` driver, registers itself as
# a driver, and exposes read-only verbs — `alerts` / `alert-groups` / `silences` /
# `silence` / `receivers` / `status`. It talks to Alertmanager over its v2 HTTP
# API using Nushell's built-in `http` (no external CLI), with no external dependencies.
#
# LAYERING (two files, like mole-prometheus's client+wrapper split):
#   - client.nu       — GENERATED, do not edit. A lean, typed HTTP client for the
#                       read-only GET endpoints, produced from Alertmanager's
#                       official Swagger 2.0 spec by `regen.nu`. It owns the
#                       mechanical parts: URL building, RFC-3986 encoding, auth,
#                       TLS, timeouts. READ-ONLY is STRUCTURAL — `regen.nu` passes
#                       `--methods [get]`, so the spec's POST/DELETE (silence &
#                       alert writes) are dropped by construction and there is no
#                       verb that can mutate anything. Its commands return the raw
#                       JSON (return types relaxed to `any`, since the API omits
#                       optional fields).
#   - alertmanager.nu — PURE response→typed-rows transforms (datetime coercion,
#                       surfacing alertname/state, flattening receiver refs).
#   - mod.nu          — THIS wrapper. It owns policy: connection resolution,
#                       result typing, and the completion catalog. Because the
#                       client is GET-only, there is no danger prompt.
#
# The generated client and the transforms are imported PRIVATELY (`use
# ./client.nu`, `use ./alertmanager.nu`), so `client alerts get`, `alertmanager
# alert`, … never leak into `use mole-alertmanager`.

use mole/lib/conn.nu

# Driver-scoped connection completer: only THIS driver (alertmanager), never other drivers.
def "complete-connection" []: nothing -> list<string> { conn names "alertmanager" }
use mole/lib/cache.nu
use mole/lib/complete.nu
use ./client.nu
use ./alertmanager.nu

export-env {
  conn register "alertmanager"
}

# ---- connection resolution ----------------------------------------------------

# Resolve an alertmanager connection (named, or the current one) and apply ad-hoc
# `--url`/`--token`/`--set` overrides. Null overrides are dropped (see `conn
# override`), so unset flags are no-ops. Asserts the connection is an
# alertmanager one.
def am-conf [connection: any, url: any, token: any, set: record]: nothing -> record {
  conn with alertmanager $connection ({url: $url, token: $token} | merge $set)
}

# The API base for the client's `--base-url`: the connection URL + `/api/v2`.
# Defaults to a local Alertmanager when the connection carries no URL.
def am-base [conf: record]: nothing -> string {
  let u = ($conf | get -o url | default "http://localhost:9093" | str trim --right --char '/')
  $"($u)/api/v2"
}

def am-token [conf: record]: nothing -> string { $conf | get -o token | default "" }
def am-insecure [conf: record]: nothing -> bool { $conf | get -o insecure | default false }

# ---- completion catalog (receiver names) --------------------------------------

# Load the completion catalog for a connection: {meta, receivers}. Cached for a
# day. `--refresh` rebuilds; otherwise a fresh cache is returned as-is. The
# catalog call is short-timeout and only powers tab-completion.
def am-catalog-load [conf: record, --refresh]: nothing -> record {
  let file = (cache path "alertmanager" ($conf | get -o name | default "_"))
  if (not $refresh) and (not (cache stale $file 1day)) { return (cache read $file) }
  let receivers = (client receivers get
    --base-url (am-base $conf) --token (am-token $conf) --insecure=(am-insecure $conf) --max-time 10sec
    | default [] | get -o name | default [])
  let data = {meta: {connection: ($conf | get -o name), driver: "alertmanager", refreshed_at: (date now)}, receivers: $receivers}
  $data | cache write $file
  $data
}

# Warm the catalog after a successful call, but only when it is cold (missing).
# Best-effort: the connection is known reachable here, so this is cheap and never
# breaks the calling command. `set-connection` is the explicit refresh point.
def am-warm [conf: record]: nothing -> nothing {
  let file = (cache path "alertmanager" ($conf | get -o name | default "_"))
  if (cache read $file | is-not-empty) { return }
  try { am-catalog-load $conf | ignore } catch { }
}

# Read a flag's value out of a completion-context command line (last wins).
def am-flag [ctx: string, names: list<string>]: nothing -> any {
  let m = ($ctx | parse --regex ('(?:' + ($names | str join "|") + ')[\s=]+(?P<v>[^\s]+)'))
  if ($m | is-empty) { null } else { $m | last | get v }
}

# The cached catalog for whatever connection the command line names (or the
# current one). Cache-only — never hits the network, so completers stay instant.
def am-catalog-ctx [context: string]: nothing -> record {
  try {
    let conf = (am-conf (am-flag $context ["--connection" "-c"]) null null {})
    (cache read (cache path "alertmanager" ($conf | get -o name | default "_"))) | default {}
  } catch { {} }
}

# Completer: known receiver names for the connection on the command line.
def "am-receiver" [context: string]: nothing -> list<string> { am-catalog-ctx $context | get -o receivers | default [] }

# ---- user verbs ---------------------------------------------------------------

# List alerts currently in Alertmanager, returning typed rows.
#
# Each row leads with `alertname` (from its labels) and `state` (active /
# suppressed / unprocessed), followed by the datetime-coerced `startsAt` /
# `endsAt` / `updatedAt`, the `fingerprint`, and the full nested `labels` /
# `annotations` / `status` / `receivers`. The four state flags map to
# Alertmanager's boolean query params and are tri-state (unset = the server
# default of true): pass `--active=false` to see only suppressed alerts,
# `--silenced=false` to hide silenced ones, and so on.
# `--filter` is a matcher expression (repeatable) like `alertname="MyAlert"`;
# `--receiver` is a regex matching the receiver an alert routes to. `--raw`
# returns the API payload untyped. Connection is the current alertmanager one
# unless `--connection` names another; `--url`/`--token`/`--set` override fields.
@category mole-alertmanager
@example "all alerts" { mole-alertmanager alerts }
@example "only suppressed (silenced or inhibited) alerts" { mole-alertmanager alerts --active=false }
@example "alerts for one alertname, on a named connection" { mole-alertmanager alerts --filter ['alertname="HighErrorRate"'] -c prod }
export def "alerts" [
  --active: oneof<nothing, bool>                   # include active alerts (unset = server default true; pass =false to exclude)
  --silenced: oneof<nothing, bool>                 # include silenced alerts (unset = server default true; pass =false to exclude)
  --inhibited: oneof<nothing, bool>                # include inhibited alerts (unset = server default true; pass =false to exclude)
  --unprocessed: oneof<nothing, bool>              # include unprocessed alerts (unset = server default true; pass =false to exclude)
  --filter(-f): list<string>                       # matcher expression(s), e.g. 'alertname="MyAlert"' (repeatable)
  --receiver(-r): string@"am-receiver"             # regex matching the receiver to filter by (completes known receiver names)
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string                                    # override the connection URL
  --token: string                                  # override the bearer token
  --set: record = {}                               # override any other connection field(s)
  --raw(-R)                                         # return the API payload, untyped
] {
  let conf = (am-conf $connection $url $token $set)
  let resp = (client alerts get
    --active $active --silenced $silenced --inhibited $inhibited --unprocessed $unprocessed
    --filter $filter --receiver $receiver
    --base-url (am-base $conf) --token (am-token $conf) --insecure=(am-insecure $conf))
  am-warm $conf
  if $raw { $resp } else { alertmanager alerts $resp }
}

# List alert groups (alerts grouped as Alertmanager routes/notifies them).
#
# Returns one row per group: its grouping `labels` and `routeLabels` (records),
# the `receiver` it routes to (flattened to the bare name), and its member
# `alerts` typed exactly as `alerts` returns them. The state switches and
# `--filter`/`--receiver` behave as in `alerts`; `--muted=false` drops groups
# whose alerts are all muted. `--raw` returns the API payload untyped.
@category mole-alertmanager
@example "all alert groups" { mole-alertmanager alert-groups }
@example "groups for one receiver regex" { mole-alertmanager alert-groups --receiver 'team-.*' }
export def "alert-groups" [
  --active: oneof<nothing, bool>                   # include active alerts within groups (unset = server default true; pass =false to exclude)
  --silenced: oneof<nothing, bool>                 # include silenced alerts within groups (unset = server default true; pass =false to exclude)
  --inhibited: oneof<nothing, bool>                # include inhibited alerts within groups (unset = server default true; pass =false to exclude)
  --muted: oneof<nothing, bool>                    # include fully-muted groups (unset = server default true; pass =false to exclude)
  --filter(-f): list<string>                       # matcher expression(s), e.g. 'alertname="MyAlert"' (repeatable)
  --receiver(-r): string@"am-receiver"             # regex matching the receiver to filter by (completes known receiver names)
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string                                    # override the connection URL
  --token: string                                  # override the bearer token
  --set: record = {}                               # override any other connection field(s)
  --raw(-R)                                         # return the API payload, untyped
] {
  let conf = (am-conf $connection $url $token $set)
  let resp = (client alerts-groups get
    --active $active --silenced $silenced --inhibited $inhibited --muted $muted
    --filter $filter --receiver $receiver
    --base-url (am-base $conf) --token (am-token $conf) --insecure=(am-insecure $conf))
  am-warm $conf
  if $raw { $resp } else { alertmanager alert-groups $resp }
}

# List silences, returning typed rows.
#
# Each row leads with the silence `id` and its `state` (active / pending /
# expired), followed by the datetime-coerced `startsAt` / `endsAt` / `updatedAt`,
# then its `matchers`, `createdBy`, `comment` and `annotations`. `--filter` is a
# matcher expression (repeatable) like `alertname="MyAlert"` that scopes which
# silences are returned. `--raw` returns the API payload untyped.
@category mole-alertmanager
@example "all silences" { mole-alertmanager silences }
@example "silences matching an alertname" { mole-alertmanager silences --filter ['alertname="HighErrorRate"'] }
export def "silences" [
  --filter(-f): list<string>                       # matcher expression(s) to filter silences (repeatable)
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string                                    # override the connection URL
  --token: string                                  # override the bearer token
  --set: record = {}                               # override any other connection field(s)
  --raw(-R)                                         # return the API payload, untyped
] {
  let conf = (am-conf $connection $url $token $set)
  let resp = (client silences get --filter $filter
    --base-url (am-base $conf) --token (am-token $conf) --insecure=(am-insecure $conf))
  am-warm $conf
  if $raw { $resp } else { alertmanager silences $resp }
}

# Get a single silence by its ID, returning one typed row (see `silences`).
@category mole-alertmanager
@example "look up a silence by id" { mole-alertmanager silence 4f8b2c1a-0e3d-4a5b-9c7e-1f2a3b4c5d6e }
export def "silence" [
  id: string                                       # the silence ID (a UUID)
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string                                    # override the connection URL
  --token: string                                  # override the bearer token
  --set: record = {}                               # override any other connection field(s)
  --raw(-R)                                         # return the API payload, untyped
] {
  let conf = (am-conf $connection $url $token $set)
  let resp = (client silence get $id
    --base-url (am-base $conf) --token (am-token $conf) --insecure=(am-insecure $conf))
  am-warm $conf
  if $raw { $resp } else { alertmanager silence $resp }
}

# List the configured receivers (notification-integration names).
#
# Returns the raw receiver table: one row per receiver with its `name` and any
# `labels`. `--matchers` filters by receiver labels, e.g. `owner="my-team"`
# (repeatable). Data is returned as the API gives it (no datetime fields here).
@category mole-alertmanager
@example "all receivers" { mole-alertmanager receivers }
@example "receivers owned by a team" { mole-alertmanager receivers --matchers ['owner="my-team"'] }
export def "receivers" [
  --matchers(-m): list<string>                     # matcher expression(s) on receiver labels (repeatable)
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string                                    # override the connection URL
  --token: string                                  # override the bearer token
  --set: record = {}                               # override any other connection field(s)
] {
  let conf = (am-conf $connection $url $token $set)
  (client receivers get --receiver-matchers $matchers
    --base-url (am-base $conf) --token (am-token $conf) --insecure=(am-insecure $conf))
  | default []
}

# Alertmanager instance & cluster status.
#
# Returns the status record — `cluster` (peer membership & state), `versionInfo`
# (build metadata), `config` (the running config's `original` text) and `uptime`
# (coerced to a `datetime`). `--raw` returns it untyped (uptime left as a string).
@category mole-alertmanager
@example "instance status" { mole-alertmanager status }
export def "status" [
  --connection(-c): string@complete-connection   # named connection (default: current)
  --url: string                                    # override the connection URL
  --token: string                                  # override the bearer token
  --set: record = {}                               # override any other connection field(s)
  --raw(-R)                                         # return the API payload, untyped
] {
  let conf = (am-conf $connection $url $token $set)
  let resp = (client status get
    --base-url (am-base $conf) --token (am-token $conf) --insecure=(am-insecure $conf))
  am-warm $conf
  if $raw { $resp } else { alertmanager status $resp }
}

# Make an alertmanager connection the current one for this driver.
#
# Records the choice in `$env.MOLE_CURRENT.alertmanager`, so later verbs can omit
# `--connection`. Validates that `name` exists and is an alertmanager connection.
# Also warms the completion catalog (receiver names) for the connection,
# best-effort — so tab-completion is ready right away.
@category mole-alertmanager
@example "make the prod connection current" { mole-alertmanager set-connection prod }
export def --env "set-connection" [
  name: string@complete-connection               # an alertmanager connection name (from the connections file)
]: nothing -> nothing {
  let conf = (conn set-current alertmanager $name)
  try { am-catalog-load $conf --refresh | ignore } catch { }
}
