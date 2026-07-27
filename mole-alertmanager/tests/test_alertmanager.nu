use std/assert
use std/testing *
use ../alertmanager.nu

# ---- datetime coercion --------------------------------------------------------

@test
def "dt parses RFC3339 strings to datetimes" [] {
    assert equal (alertmanager dt "2023-11-14T22:13:20Z") 2023-11-14T22:13:20Z
    assert equal (alertmanager dt "2023-11-14T22:13:20.123Z") 2023-11-14T22:13:20.123Z   # millis
    assert equal ((alertmanager dt "2023-11-14T22:13:20Z") | describe) "datetime"
}

@test
def "dt keeps null and empty as null, never the epoch" [] {
    assert equal (alertmanager dt null) null
    assert equal (alertmanager dt "") null
}

@test
def "dt passes a value it cannot parse through untouched" [] {
    assert equal (alertmanager dt "not-a-date") "not-a-date"
    assert equal (alertmanager dt 2023-11-14T22:13:20Z) 2023-11-14T22:13:20Z   # already a datetime
}

@test
def "coerce-times converts only the time fields that are present" [] {
    let out = alertmanager coerce-times {startsAt: "2023-11-14T22:13:20Z", comment: "hi"}
    assert equal $out {startsAt: 2023-11-14T22:13:20Z, comment: "hi"}
    assert equal (alertmanager coerce-times {comment: "hi"}) {comment: "hi"}   # nothing to coerce
}

# ---- reorder ------------------------------------------------------------------

@test
def "reorder leads with present keys and invents none" [] {
    assert equal (alertmanager reorder {c: 3, a: 1, b: 2} [a b z]) {a: 1, b: 2, c: 3}
    # a requested-but-absent key (z) is not added as a null column
    assert equal (alertmanager reorder {c: 3, a: 1, b: 2} [a b z] | columns) [a b c]
}

# ---- alerts -------------------------------------------------------------------

@test
def "alert surfaces alertname and state, coerces times, keeps records" [] {
    let out = alertmanager alert {labels: {alertname: Down, job: api}, status: {state: active}, startsAt: "2023-11-14T22:13:20Z", fingerprint: "ab"}
    assert equal $out {alertname: Down, state: active, startsAt: 2023-11-14T22:13:20Z, fingerprint: ab, labels: {alertname: Down, job: api}, status: {state: active}}
}

@test
def "alert orders columns and does not pad absent optionals" [] {
    let full = alertmanager alert {annotations: {summary: x}, receivers: [{name: r1}], fingerprint: fp, startsAt: "2023-11-14T22:13:20Z", updatedAt: "2023-11-14T22:13:21Z", endsAt: "2023-11-14T22:13:22Z", status: {state: suppressed, silencedBy: [s1], inhibitedBy: [], mutedBy: []}, labels: {alertname: Down}, generatorURL: "http://x"}
    assert equal ($full | columns) [alertname state startsAt endsAt updatedAt fingerprint generatorURL labels annotations status receivers]
    # a minimal alert carries only what it has (plus the two surfaced scalars)
    let min = alertmanager alert {labels: {alertname: Down}, status: {state: active}, fingerprint: fp}
    assert equal ($min | columns) [alertname state fingerprint labels status]
}

@test
def "alerts types each row and passes non-lists through" [] {
    let out = alertmanager alerts [{labels: {alertname: Down}, status: {state: active}, startsAt: "2023-11-14T22:13:20Z"}]
    assert equal $out [{alertname: Down, state: active, startsAt: 2023-11-14T22:13:20Z, labels: {alertname: Down}, status: {state: active}}]
    assert equal (alertmanager alerts []) []
    assert equal (alertmanager alerts "oops") "oops"
}

# ---- silences -----------------------------------------------------------------

@test
def "silence surfaces id and state and coerces times" [] {
    let out = alertmanager silence {id: s1, status: {state: active}, startsAt: "2023-11-14T22:13:20Z", createdBy: me, comment: wip}
    assert equal $out {id: s1, state: active, startsAt: 2023-11-14T22:13:20Z, createdBy: me, comment: wip, status: {state: active}}
}

@test
def "silences types each row and passes non-lists through" [] {
    let out = alertmanager silences [{id: s1, status: {state: expired}, endsAt: "2023-11-14T22:13:20Z"}]
    assert equal $out [{id: s1, state: expired, endsAt: 2023-11-14T22:13:20Z, status: {state: expired}}]
    assert equal (alertmanager silences []) []
}

# ---- alert groups -------------------------------------------------------------

@test
def "alert-group flattens the receiver and types member alerts" [] {
    let out = alertmanager alert-group {labels: {alertname: Down}, routeLabels: {}, receiver: {name: team-x}, alerts: [{labels: {alertname: Down}, status: {state: active}, startsAt: "2023-11-14T22:13:20Z"}]}
    assert equal $out.receiver team-x
    assert equal ($out.alerts | first) {alertname: Down, state: active, startsAt: 2023-11-14T22:13:20Z, labels: {alertname: Down}, status: {state: active}}
    assert equal $out.labels {alertname: Down}
}

@test
def "alert-groups types each group and handles empty alert lists" [] {
    let out = alertmanager alert-groups [{labels: {}, routeLabels: {}, receiver: {name: team-x}, alerts: []}]
    assert equal $out [{labels: {}, routeLabels: {}, receiver: team-x, alerts: []}]
}

# ---- status -------------------------------------------------------------------

@test
def "status coerces uptime and leaves the rest of the record intact" [] {
    let out = alertmanager status {cluster: {status: ready}, versionInfo: {version: "0.27.0"}, config: {original: "x"}, uptime: "2023-11-14T22:13:20Z"}
    assert equal $out.uptime 2023-11-14T22:13:20Z
    assert equal ($out.uptime | describe) "datetime"
    assert equal $out.cluster {status: ready}
}

@test
def "status without an uptime is returned untouched" [] {
    assert equal (alertmanager status {cluster: {status: settling}}) {cluster: {status: settling}}
}
