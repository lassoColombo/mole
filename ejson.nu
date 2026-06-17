# Recursive decoder for mongosh's canonical Extended JSON output.
#
# mongosh emits BSON types as tagged-record wrappers (e.g. `{"$oid": "..."}`,
# `{"$date": "..."}`, `{"$numberLong": "..."}`). This walker unwraps them into
# native nushell values so the rest of the pipeline can work in nu types
# instead of EJSON structures.
#
# Detection dispatches on the discriminator `$`-tag. Records without a known
# wrapper key — DBRefs (`$ref/$id/$db`) and plain documents — fall through to
# a per-value recursion, so any wrappers nested inside them still decode.
#
# The driver runs mongosh with `--json=canonical` so every numeric is wrapped;
# in relaxed mode JS would silently truncate `$numberLong > 2^53` to a double.

# Walk a value and unwrap any EJSON wrappers found inside it.
export def decode []: any -> any {
  let v = $in
  let kind = $v | describe -d | get type
  match $kind {
    "record" => (decode-record $v)
    "list"   => ($v | each { $in | decode })
    _        => $v
  }
}

def decode-record [r: record]: nothing -> any {
  let ks = $r | columns
  if ($ks | is-empty) { return $r }

  if "$oid"               in $ks { return ($r | get '$oid') }
  if "$numberInt"         in $ks { return ($r | get '$numberInt'    | into int) }
  if "$numberLong"        in $ks { return ($r | get '$numberLong'   | into int) }
  if "$numberDouble"      in $ks { return ($r | get '$numberDouble' | into float) }
  if "$numberDecimal"     in $ks { return ($r | get '$numberDecimal' | into float) }
  if "$date"              in $ks { return (decode-date ($r | get '$date')) }
  if "$timestamp"         in $ks { return (decode-timestamp ($r | get '$timestamp')) }
  if "$binary"            in $ks { return (decode-binary ($r | get '$binary')) }
  if "$regularExpression" in $ks { return (decode-regex ($r | get '$regularExpression')) }
  if "$code"              in $ks { return (decode-code $r) }
  if "$undefined"         in $ks { return null }
  if "$symbol"            in $ks { return ($r | get '$symbol') }
  if "$minKey"            in $ks { return $r }
  if "$maxKey"            in $ks { return $r }

  $r
  | items {|k, v| {key: $k, val: ($v | decode)} }
  | reduce -f {} {|x, acc| $acc | upsert $x.key $x.val }
}

# `$date` payload is either an ISO-8601 string (relaxed mode, in-range dates)
# or `{$numberLong: "<ms-since-epoch>"}` (canonical mode, or relaxed for dates
# pre-1970 / far-future).
#
# nu durations are i64 nanoseconds → ~292-year span from epoch (~1678–2262).
# A `$numberLong` ms outside that window overflows on `* 1ms`; in that
# (vanishingly rare) case we pass the wrapper through untouched rather than
# silently fabricating a wrong value.
def decode-date [v: any]: nothing -> any {
  if ($v | describe -d | get type) == "string" {
    return ($v | into datetime)
  }
  let ms = $v | get '$numberLong' | into int
  try {
    ("1970-01-01T00:00:00Z" | into datetime) + ($ms * 1ms)
  } catch {
    { '$date': { '$numberLong': ($ms | into string) } }
  }
}

# BSON Timestamp (replication-internal): seconds + increment counter.
def decode-timestamp [v: record]: nothing -> record {
  {
    t: (("1970-01-01T00:00:00Z" | into datetime) + (($v.t | into int) * 1sec))
    i: ($v.i | into int)
  }
}

# subType 04 → canonical UUID string; everything else → decoded bytes + subtype tag.
def decode-binary [v: record]: nothing -> any {
  let bytes = $v.base64 | decode base64
  if $v.subType == "04" {
    let h = $bytes | encode hex | str downcase
    return $"($h | str substring 0..7)-($h | str substring 8..11)-($h | str substring 12..15)-($h | str substring 16..19)-($h | str substring 20..31)"
  }
  { data: $bytes, subtype: $v.subType }
}

def decode-regex [v: record]: nothing -> record {
  { pattern: $v.pattern, options: $v.options }
}

def decode-code [r: record]: nothing -> record {
  let code = $r | get '$code'
  if "$scope" in ($r | columns) {
    { code: $code, scope: ($r | get '$scope' | decode) }
  } else {
    { code: $code }
  }
}
