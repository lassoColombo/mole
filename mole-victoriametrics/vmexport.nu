# mole-victoriametrics/vmexport — the ONE VictoriaMetrics-specific result transform.
#
# The query-API wire format and the PromQL builder are identical to Prometheus and
# come from the shared `mole-promql` library (mod.nu imports it directly); this file
# holds only what that library cannot know: the columnar `/api/v1/export` shape.
use mole-promql/promql.nu

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
  vmexport export-lines [{metric: {__name__: up, job: api}, values: [1, 0], timestamps: [0, 60000]}]
} --result [{metric: up, job: api, timestamp: 1970-01-01T00:00:00Z, value: 1.0}, {metric: up, job: api, timestamp: 1970-01-01T00:01:00Z, value: 0.0}]
export def "export-lines" [lines: list]: nothing -> table {
  $lines | each {|s|
    let labels = (promql relabel ($s | get -o metric | default {}))
    let vals = ($s | get -o values | default [])
    ($s | get -o timestamps | default []) | enumerate | each {|t|
      $labels | merge {
        timestamp: (promql time (($t.item | into float) / 1000))
        value: (promql num ($vals | get -o $t.index) --coerce {|x| $x | into float })
      }
    }
  } | flatten
}
