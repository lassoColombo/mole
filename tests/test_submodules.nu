use std/assert
use std/testing *
use ../submodules.nu

# Self-locate this test file to derive the workspace robustly (CI-portable).
# tests/ -> mole/ -> workspace/. `path self` is available at const scope.
const TESTS_DIR = (path self | path dirname)
const MOLE_DIR = ($TESTS_DIR | path dirname)
const WORKSPACE = ($MOLE_DIR | path dirname)

# Create ephemeral sibling manifests in the workspace. Each test gets uniquely
# named plugin + lib fixtures so parallel runs don't collide. Never touches
# real siblings.
@before-each
def setup [] {
  let core_api = (open ([$MOLE_DIR "mole.nuon"] | path join) | get api)
  let tag = (random chars -l 8)

  let plugin_name = $"mole-nutest-plugin-($tag)"
  let plugin_dir = ([$WORKSPACE $plugin_name] | path join)
  mkdir $plugin_dir
  {
    kind: "plugin"
    source: $plugin_name
    version: "0.1.0"
    api: $core_api
    drivers: ["drv-a"]
    deps: [{module: "mole-sql", version: "0.1.0"}]
    summary: "ephemeral nutest plugin fixture"
  } | to nuon | save ([$plugin_dir "mole.nuon"] | path join)

  let lib_name = $"mole-nutest-lib-($tag)"
  let lib_dir = ([$WORKSPACE $lib_name] | path join)
  mkdir $lib_dir
  {
    kind: "lib"
    version: "0.2.0"
    api: $core_api
    deps: []
    summary: "ephemeral nutest lib fixture"
  } | to nuon | save ([$lib_dir "mole.nuon"] | path join)

  {
    core_api: $core_api
    plugin_name: $plugin_name
    plugin_dir: $plugin_dir
    lib_name: $lib_name
    lib_dir: $lib_dir
  }
}

@after-each
def teardown [] {
  let ctx = $in
  rm -rf $ctx.plugin_dir
  rm -rf $ctx.lib_dir
}

@test
def "list includes plugin fixture with kind version and deps as list" [] {
  let ctx = $in
  let row = (submodules list | where module == $ctx.plugin_name | first)
  assert equal $row.kind "plugin"
  assert equal $row.version "0.1.0"
  assert equal $row.deps [{module: "mole-sql", version: "0.1.0"}]
}

@test
def "sources includes plugin but excludes lib" [] {
  let ctx = $in
  let out = (submodules sources)
  let plugin_sources = ($out | where source == $ctx.plugin_name)
  assert equal ($plugin_sources | length) 1
  # lib fixture must not surface as a source (its dir name never appears)
  assert equal ($out | where source == $ctx.lib_name | length) 0
}

@test
def "doctor api_ok true when api matches core major" [] {
  let ctx = $in
  let row = (submodules doctor | where module == $ctx.plugin_name | first)
  assert equal $row.api_ok true
}

@test
def "doctor api_ok false for higher major api target" [] {
  let ctx = $in
  # Rewrite the plugin fixture to target an incompatible major.
  {
    kind: "plugin"
    source: $ctx.plugin_name
    version: "0.1.0"
    api: "999.0.0"
    deps: []
    summary: "higher major"
  } | to nuon | save -f ([$ctx.plugin_dir "mole.nuon"] | path join)
  let row = (submodules doctor | where module == $ctx.plugin_name | first)
  assert equal $row.api_ok false
}

@test
def "install rejects name without mole- prefix" [] {
  assert error { submodules install "nope" "http://x" }
  # guard fires before clone: nothing created in workspace
  assert (not ([$WORKSPACE "nope"] | path join | path exists))
}

@test
def "uninstall errors when not installed" [] {
  assert error { submodules uninstall "mole-does-not-exist-xyz" }
}
