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

@test
def "fetch builds, stamps refreshed_at, then serves the cache until refresh" [] {
    let ctx = $in
    $env.XDG_CACHE_HOME = $ctx.temp
    let f = (cache path "t" "k")
    let built = (cache fetch $f 1hr {|| {meta: {connection: "c"}, rows: [1]} })
    assert equal $built.rows [1]
    assert equal $built.meta.connection "c"
    assert equal ($built.meta.refreshed_at | describe) "datetime"
    assert equal (cache fetch $f 1hr {|| {rows: [2]} }).rows [1]            # fresh → served, not rebuilt
    assert equal (cache fetch $f 1hr {|| {rows: [3]} } --refresh).rows [3]  # forced rebuild
    assert equal (cache read $f).rows [3]
}

@test
def "fetch rebuilds a stale cache" [] {
    let ctx = $in
    $env.XDG_CACHE_HOME = $ctx.temp
    let f = (cache path "t" "k")
    {meta: {refreshed_at: ((date now) - 2hr)}, rows: [1]} | cache write $f
    assert equal (cache fetch $f 1hr {|| {rows: [2]} }).rows [2]
}
