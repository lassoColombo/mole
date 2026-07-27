use std/assert
use std/testing *
use ../promql.nu

# The shared response transforms (num/time/ts/step/relabel/vector/matrix/scalar/
# normalize/metadata) live in the generic `mole-promql` library and are tested
# there. This file covers only the VM-SPECIFIC transform: the columnar /export
# shape (native-number values, MILLISECOND timestamps), which re-uses the library
# helpers with the injected `--coerce` for native numbers.

# ---- VictoriaMetrics /export (columnar JSON lines, MILLISECOND timestamps) -----

@test
def "export-lines flattens columnar series to tidy rows" [] {
    let out = promql export-lines [{metric: {__name__: up, job: api}, values: [1, 0], timestamps: [0, 60000]}]
    assert equal ($out | length) 2
    assert equal ($out | first) {metric: up, job: api, timestamp: 1970-01-01T00:00:00Z, value: 1.0}
    assert equal ($out | last) {metric: up, job: api, timestamp: 1970-01-01T00:01:00Z, value: 0.0}
}

@test
def "export-lines coerces native-number values to float via the injected --coerce" [] {
    # /export values are native JSON ints; export-lines injects float coercion, so
    # they come back as floats (the shared `num` would otherwise pass them through).
    let out = promql export-lines [{metric: {job: api}, values: [5], timestamps: [0]}]
    assert equal $out [{job: api, timestamp: 1970-01-01T00:00:00Z, value: 5.0}]
    assert equal (($out | first | get value) | describe) "float"
}

@test
def "export-lines handles empty input" [] {
    assert equal (promql export-lines []) []
}
