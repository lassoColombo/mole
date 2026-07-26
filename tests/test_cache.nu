use std/assert
use std/testing *
use ../lib/cache.nu

@before-each
def setup [] {
    let temp = mktemp --tmpdir --directory
    { temp: $temp }
}

@after-each
def cleanup [] {
    rm --recursive $in.temp
}

@test
def "path sanitizes key and lives under cache dir" [] {
    let ctx = $in
    $env.XDG_CACHE_HOME = $ctx.temp
    let p = cache path "src" "a b/c"
    assert str contains $p $ctx.temp
    assert str contains $p ([mole src] | path join)
    assert str contains $p "a_b_c.nuon"
    let seg = $p | path basename
    assert equal $seg "a_b_c.nuon"
    assert (not ($seg | str contains " "))
    assert (not ($seg | str contains "/"))
}

@test
def "write then read roundtrips the record" [] {
    let ctx = $in
    $env.XDG_CACHE_HOME = $ctx.temp
    let f = cache path "src" "k"
    { meta: { refreshed_at: (date now) }, rows: [1 2 3] } | cache write $f
    let got = cache read $f
    assert equal $got.rows [1 2 3]
}

@test
def "stale is true when file is missing" [] {
    let ctx = $in
    $env.XDG_CACHE_HOME = $ctx.temp
    let f = cache path "src" "missing"
    assert (cache stale $f 1hr)
}

@test
def "stale is false right after fresh write" [] {
    let ctx = $in
    $env.XDG_CACHE_HOME = $ctx.temp
    let f = cache path "src" "fresh"
    { meta: { refreshed_at: (date now) }, rows: [1] } | cache write $f
    assert (not (cache stale $f 1hr))
}

@test
def "stale is true when old, and clear removes the file" [] {
    let ctx = $in
    $env.XDG_CACHE_HOME = $ctx.temp
    let f = cache path "src" "old"
    { meta: { refreshed_at: ((date now) - 2hr) }, rows: [1] } | cache write $f
    assert (cache stale $f 1hr)
    cache clear $f
    assert equal (cache read $f) null
}
