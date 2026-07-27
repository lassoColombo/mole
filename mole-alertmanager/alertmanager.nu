# mole-alertmanager/alertmanager — PURE response-shaping helpers for the
# Alertmanager v2 HTTP API. Data-in / data-out: NO I/O and NO clock. These turn
# the JSON payloads the generated client returns into typed Nushell rows.
#
# LAYERING: mod.nu imports this PRIVATELY (`use ./alertmanager.nu`) and the tests
# import it directly; nothing here is re-exported into `use mole-alertmanager`.
# Keeping the transforms pure is what makes them unit-testable (see
# tests/test_alertmanager.nu).
#
# Alertmanager encodes every timestamp as an RFC3339 string
# ("2026-07-26T00:00:00.000Z"); `labels`/`annotations` are string→string maps
# and `status` is a small record. These helpers own the datetime coercion and the
# surfacing of the two fields you scan by (alertname, state) as leading columns,
# while keeping the full nested `labels`/`annotations`/`status` records intact.

# An RFC3339 datetime string → a real `datetime`. An empty/null value stays null
# (so a missing `endsAt` doesn't become the epoch); anything `into datetime`
# can't parse is kept as-is, and a value that is already a datetime passes through.
@category mole-alertmanager
@example "an RFC3339 string becomes a datetime" { alertmanager dt "2023-11-14T22:13:20Z" } --result 2023-11-14T22:13:20Z
@example "null stays null" { alertmanager dt null } --result null
export def "dt" [v: any]: nothing -> any {
  if ($v | is-empty) { return null }
  if ($v | describe) == "datetime" { return $v }
  try { $v | into datetime } catch { $v }
}

# Coerce the RFC3339 timestamp fields present on a record to `datetime`, in place.
# Only the fields that exist are touched; the rest of the record is untouched.
# Shared by `alert` and `silence` (both carry startsAt/endsAt/updatedAt).
@category mole-alertmanager
@example "coerces the time fields it finds" {
  alertmanager coerce-times {startsAt: "2023-11-14T22:13:20Z", comment: "hi"}
} --result {startsAt: 2023-11-14T22:13:20Z, comment: "hi"}
export def "coerce-times" [r: record]: nothing -> record {
  ["startsAt" "endsAt" "updatedAt"] | reduce --fold $r {|f, acc|
    if ($f in ($acc | columns)) { $acc | upsert $f (dt ($acc | get $f)) } else { $acc }
  }
}

# Reorder a record's columns to a preferred leading order, WITHOUT inventing
# absent columns: only the `order` keys actually present are pulled to the front
# (in that order), and any remaining columns keep their original relative order.
# This is how `alert`/`silence` present a scannable column layout while staying
# faithful to which optional fields the API actually returned.
@category mole-alertmanager
@example "leads with present keys, keeps the rest, invents nothing" {
  alertmanager reorder {c: 3, a: 1, b: 2} [a b z]
} --result {a: 1, b: 2, c: 3}
export def "reorder" [r: record, order: list<string>]: nothing -> record {
  let present = ($r | columns)
  let lead = ($order | where {|k| $k in $present })
  let rest = ($present | where {|k| $k not-in $lead })
  $r | select ...$lead ...$rest
}

# A gettableAlert → a typed row. Leads with `alertname` (from `labels.alertname`)
# and `state` (from `status.state`) for at-a-glance scanning, then the datetime-
# coerced timestamps, then the full nested records (`labels`, `annotations`,
# `status`, `receivers`) and scalars (`fingerprint`, `generatorURL`) as the API
# returns them. A non-record passes through untouched.
@category mole-alertmanager
@example "surfaces alertname/state and coerces times" {
  alertmanager alert {labels: {alertname: Down, job: api}, status: {state: active}, startsAt: "2023-11-14T22:13:20Z", fingerprint: "ab"}
} --result {alertname: Down, state: active, startsAt: 2023-11-14T22:13:20Z, fingerprint: ab, labels: {alertname: Down, job: api}, status: {state: active}}
export def "alert" [a: any]: nothing -> any {
  if (($a | describe) !~ '^record') { return $a }
  let surfaced = {alertname: ($a | get -o labels.alertname), state: ($a | get -o status.state)}
  reorder ($surfaced | merge (coerce-times $a)) [alertname state startsAt endsAt updatedAt fingerprint generatorURL labels annotations status receivers]
}

# A gettableAlerts array → a table of typed alert rows.
@category mole-alertmanager
@example "types each alert in a list" {
  alertmanager alerts [{labels: {alertname: Down}, status: {state: active}, startsAt: "2023-11-14T22:13:20Z"}]
} --result [{alertname: Down, state: active, startsAt: 2023-11-14T22:13:20Z, labels: {alertname: Down}, status: {state: active}}]
export def "alerts" [result: any]: nothing -> any {
  if (($result | describe) !~ '^(list|table)') { return $result }
  $result | each {|a| alert $a }
}

# A gettableSilence → a typed row. Leads with `id` and `state` (from
# `status.state`), then the datetime-coerced timestamps, then the rest
# (`matchers` list, `createdBy`, `comment`, `annotations`, `status`).
@category mole-alertmanager
@example "surfaces id/state and coerces times" {
  alertmanager silence {id: s1, status: {state: active}, startsAt: "2023-11-14T22:13:20Z", createdBy: me, comment: wip}
} --result {id: s1, state: active, startsAt: 2023-11-14T22:13:20Z, createdBy: me, comment: wip, status: {state: active}}
export def "silence" [s: any]: nothing -> any {
  if (($s | describe) !~ '^record') { return $s }
  let surfaced = {id: ($s | get -o id), state: ($s | get -o status.state)}
  reorder ($surfaced | merge (coerce-times $s)) [id state startsAt endsAt updatedAt matchers createdBy comment annotations status]
}

# A gettableSilences array → a table of typed silence rows.
@category mole-alertmanager
@example "types each silence in a list" {
  alertmanager silences [{id: s1, status: {state: expired}, endsAt: "2023-11-14T22:13:20Z"}]
} --result [{id: s1, state: expired, endsAt: 2023-11-14T22:13:20Z, status: {state: expired}}]
export def "silences" [result: any]: nothing -> any {
  if (($result | describe) !~ '^(list|table)') { return $result }
  $result | each {|s| silence $s }
}

# An alertGroup → a typed group: its member `alerts` are typed with `alert`, and
# `receiver` is flattened from `{name}` to the bare receiver name for readability.
# `labels`/`routeLabels` stay as records. A non-record passes through untouched.
@category mole-alertmanager
@example "types member alerts and flattens the receiver" {
  alertmanager alert-group {labels: {alertname: Down}, receiver: {name: team-x}, alerts: [{labels: {alertname: Down}, status: {state: active}, startsAt: "2023-11-14T22:13:20Z"}]}
} --result {labels: {alertname: Down}, receiver: team-x, alerts: [{alertname: Down, state: active, startsAt: 2023-11-14T22:13:20Z, labels: {alertname: Down}, status: {state: active}}]}
export def "alert-group" [g: any]: nothing -> any {
  if (($g | describe) !~ '^record') { return $g }
  $g
  | upsert receiver ($g | get -o receiver.name)
  | upsert alerts (alerts ($g | get -o alerts | default []))
}

# An alertGroups array → a table of typed alert groups.
@category mole-alertmanager
@example "types each group in a list" {
  alertmanager alert-groups [{labels: {}, receiver: {name: team-x}, alerts: []}]
} --result [{labels: {}, receiver: team-x, alerts: []}]
export def "alert-groups" [result: any]: nothing -> any {
  if (($result | describe) !~ '^(list|table)') { return $result }
  $result | each {|g| alert-group $g }
}

# An alertmanagerStatus → the same record with `uptime` coerced to `datetime`.
# A non-record passes through untouched.
@category mole-alertmanager
@example "coerces uptime to a datetime" {
  alertmanager status {uptime: "2023-11-14T22:13:20Z", cluster: {status: ready}}
} --result {uptime: 2023-11-14T22:13:20Z, cluster: {status: ready}}
export def "status" [s: any]: nothing -> any {
  if (($s | describe) !~ '^record') { return $s }
  if ("uptime" in ($s | columns)) { $s | upsert uptime (dt $s.uptime) } else { $s }
}
