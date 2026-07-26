use std/assert
use std/testing *
use ../lib/config.nu

@before-each
def setup [] {
  { temp: (mktemp --tmpdir --directory) }
}

@after-each
def cleanup [] {
  rm --recursive --force $in.temp
}

@test
def "file is under XDG mole dir" [] {
  let temp = $in.temp
  $env.XDG_CONFIG_HOME = $temp
  assert equal (config file) ([$temp mole connections.yaml] | path join)
}

@test
def "querydir is under XDG mole dir" [] {
  let temp = $in.temp
  $env.XDG_CONFIG_HOME = $temp
  assert equal (config querydir) ([$temp mole queries] | path join)
}

@test
def "file and querydir share the mole parent" [] {
  let temp = $in.temp
  $env.XDG_CONFIG_HOME = $temp
  assert equal (config file | path dirname) (config querydir | path dirname)
}
