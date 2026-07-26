use std/assert
use std/testing *
use ../lib/query.nu

@before-each
def setup [] {
  let temp = mktemp --tmpdir --directory
  mkdir ([$temp mole queries] | path join)
  "SELECT 1" | save ([$temp mole queries hello.sql] | path join)
  { temp: $temp }
}

@after-each
def cleanup [] {
  rm --recursive $in.temp
}

@test
def "confirm --yes returns true" [] {
  assert equal (query confirm "proceed?" --yes) true
}

@test
def "check returns stdout on exit 0" [] {
  let r = { exit_code: 0, stdout: "ok", stderr: "" } | query check
  assert equal $r "ok"
}

@test
def "check errors on nonzero exit" [] {
  assert error { { exit_code: 1, stdout: "", stderr: "boom" } | query check }
}

@test
def "check error message contains stderr" [] {
  try {
    { exit_code: 1, stdout: "", stderr: "boom" } | query check
    error make { msg: "expected error but none thrown" }
  } catch { |e|
    assert str contains $e.msg "boom"
  }
}

@test
def "resolve --file returns raw file contents" [] {
  let ctx = $in
  $env.XDG_CONFIG_HOME = $ctx.temp
  let r = query resolve --file "hello.sql"
  assert equal $r "SELECT 1"
}
