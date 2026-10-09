use std/assert
use std/testing *
use ../lib/editor.nu

@test
def "launch runs EDITOR directly on the target" [] {
  $env.EDITOR = "echo"
  assert equal (editor launch "/tmp/x.sql" | str trim) "/tmp/x.sql"
}

@test
def "launch splits flags off EDITOR" [] {
  $env.EDITOR = "echo -n --wait"
  assert equal (editor launch "a b") "--wait a b"
}

@test
def "launch with cwd starts the editor in that directory" [] {
  let d = (mktemp --tmpdir --directory)
  $env.EDITOR = "sh -c pwd"
  assert equal (editor launch "ignored" --cwd $d | str trim | path expand) ($d | path expand)
}
