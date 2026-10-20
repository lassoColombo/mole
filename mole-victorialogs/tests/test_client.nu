use std/assert
use std/testing *
use ../client.nu

# ---- form encoding (pure; no server) ------------------------------------------

@test
def "form-body drops null and empty params and percent-encodes the rest" [] {
    assert equal (client form-body {query: "level:error | stats count()", start: null, limit: 0, end: ""}) "query=level%3Aerror%20%7C%20stats%20count%28%29&limit=0"
}

@test
def "form-body repeats a list param once per item" [] {
    # VictoriaLogs' /hits `field` is repeatable — one `field=` pair per group field
    assert equal (client form-body {query: "*", field: [level host]}) "query=%2A&field=level&field=host"
    assert equal (client form-body {query: "*", field: []}) "query=%2A"
}
