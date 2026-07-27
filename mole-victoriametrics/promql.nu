# mole-victoriametrics/promql — the shared Prometheus-HTTP-API helpers, plus the
# ONE VictoriaMetrics-specific transform.
#
# The wire format (vector/matrix/scalar/string envelopes, string sample values,
# Unix-seconds timestamps, {metric: [{type, help, unit}]} metadata) and the PromQL
# query builder are IDENTICAL to Prometheus, so they come from the generic
# `mole-promql` LIBRARY — re-exported here unchanged. mod.nu imports THIS file
# (`use ./promql.nu`), so `promql num`, `promql normalize`, `promql build`, … all
# resolve, exactly as before, alongside the VM-only `export-lines` below.
export use mole-promql/promql.nu *

# VM-specific: /api/v1/export streams one JSON object PER LINE, each
# {metric: {..labels}, values: [..], timestamps: [..ms..]} — a columnar dump, NOT
# the {status, data} envelope. Turn it into tidy rows: one per (series, sample),
# {..labels, timestamp, value}.
#
# TWO peculiarities the shared library does NOT bake in, handled right here:
#   - values are native JSON NUMBERS (not the query API's strings), so `num` is
#     given `--coerce {|x| $x | into float}` — the injected superset form.
#   - timestamps are MILLISECONDS (not the query API's float seconds), so they are
#     divided by 1000 before `time`.
@category mole-victoriametrics
@example "flatten one exported series" {
  promql export-lines [{metric: {__name__: up, job: api}, values: [1, 0], timestamps: [0, 60000]}]
} --result [{metric: up, job: api, timestamp: 1970-01-01T00:00:00Z, value: 1.0}, {metric: up, job: api, timestamp: 1970-01-01T00:01:00Z, value: 0.0}]
export def "export-lines" [lines: list]: nothing -> table {
  $lines | each {|s|
    let labels = (relabel ($s | get -o metric | default {}))
    let vals = ($s | get -o values | default [])
    ($s | get -o timestamps | default []) | enumerate | each {|t|
      $labels | merge {
        timestamp: (time (($t.item | into float) / 1000))
        value: (num ($vals | get -o $t.index) --coerce {|x| $x | into float })
      }
    }
  } | flatten
}
