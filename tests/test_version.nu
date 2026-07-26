use std/assert
use std/testing *
use ../lib/version.nu

# Resolve mole's manifest by THIS file's location (parse-time, CWD-independent),
# so the suite passes regardless of the process working directory.
const MANIFEST = (path self | path dirname | path dirname | path join "mole.nuon")

# api-version reports exactly what the manifest declares.
@test
def "api-version matches manifest" [] {
    let expected = (open $MANIFEST | get api)
    assert equal (version api-version) $expected
}

# A wanted api with the SAME major as what mole provides is caret-compatible: no error.
@test
def "require-api same major does not error" [] {
    let major = (open $MANIFEST | get api | into semver | get major)
    let wanted = $"($major).0.0"
    # require-api returns nothing on success and throws on failure; a throw fails the test.
    assert equal (version require-api $wanted) null
}

# A wanted api with a HIGHER major is incompatible: require-api errors.
@test
def "require-api higher major errors" [] {
    let major = (open $MANIFEST | get api | into semver | get major)
    let wanted = $"(($major) + 1).0.0"
    assert error { version require-api $wanted }
}
