use std/assert
use std/testing *
use ../client.nu

# The generated client is private to mod.nu; this pins the one hand-applied fix
# regen.nu re-applies on every run: `match[]` is a REPEATABLE query param.

# How many `match[]=` params a dry-run URL carries.
def match-count [url: string]: nothing -> int {
  $url | split row "&" | where {|q| ($q | str replace --regex '^[^?]*\?' '') | str starts-with "match%5B%5D=" } | length
}

@test
def "two selectors become two repeated match params, each RFC-3986 encoded" [] {
  let u = (client series get --qp-match ['up{a="1"}' 'down'] --dry-run | get url)
  assert equal (match-count $u) 2
  assert str contains $u 'match%5B%5D=up%7Ba%3D%221%22%7D&match%5B%5D=down'
  assert equal (match-count (client labels get --qp-match [a b] --dry-run | get url)) 2
  assert equal (match-count (client label-values get job --qp-match [a b] --dry-run | get url)) 2
}

@test
def "no selector sends no match param and keeps the other params" [] {
  let u = (client series get --start "1" --end "2" --dry-run | get url)
  assert equal (match-count $u) 0
  assert equal $u "http://localhost:9090/api/v1/series?start=1&end=2"
}
