use std/assert
use std/testing *
use ../myql.nu

# ---- dialect constants --------------------------------------------------------

@test
def "nulls is the batch-mode NULL placeholder" [] {
    assert equal (myql nulls) ["NULL"]
}

@test
def "lock-modes lists the three offered locks" [] {
    assert equal (myql lock-modes) [update share share-mode]
}

@test
def "dangerous matches writes and DDL but not reads" [] {
    let re = (myql dangerous)
    assert ("DROP TABLE t" =~ $re)
    assert ("UPDATE t SET x = 1" =~ $re)
    assert ("insert into t values (1)" =~ $re)
    assert (not ("SELECT * FROM t" =~ $re))
    assert (not ("show tables" =~ $re))
}

# ---- information_schema introspection -----------------------------------------

@test
def "introspection SQL targets information_schema with common aliases" [] {
    assert str contains (myql tables-sql) "information_schema.tables"
    assert str contains (myql tables-sql) "AS `row_estimate`"
    assert str contains (myql columns-sql) "column_type   AS `udt_name`"
    assert str contains (myql constraints-sql) "key_column_usage"
}

# ---- display-type -------------------------------------------------------------

@test
def "display-type prefers the full column_type over the bare data_type" [] {
    assert equal (myql display-type {data_type: varchar, udt_name: "varchar(255)"}) "varchar(255)"
}

@test
def "display-type falls back to data_type when column_type is absent" [] {
    assert equal (myql display-type {data_type: int}) "int"
}

# ---- cell-type (the SHARED coercions; JSON is deliberately NOT here) -----------

@test
def "cell-type maps a width-one tinyint to a boolean" [] {
    let f = (myql cell-type {data_type: tinyint, display_type: "tinyint(1)"})
    assert equal ("1" | do $f) true
    assert equal ("0" | do $f) false
}

@test
def "cell-type maps the integer family to int" [] {
    assert equal ("42" | do (myql cell-type {data_type: int})) 42
    assert equal ("99" | do (myql cell-type {data_type: bigint})) 99
    # a tinyint that is NOT tinyint(1) is a plain integer
    assert equal ("5" | do (myql cell-type {data_type: tinyint, display_type: "tinyint(4)"})) 5
}

@test
def "cell-type maps float and decimal to float" [] {
    assert equal ("1.5" | do (myql cell-type {data_type: decimal})) 1.5
    assert equal ("2.0" | do (myql cell-type {data_type: double})) 2.0
}

@test
def "cell-type maps the date family to datetime" [] {
    assert equal ("2020-01-02" | do (myql cell-type {data_type: date})) ("2020-01-02" | into datetime)
}

@test
def "cell-type leaves text and JSON alone as a null converter" [] {
    assert equal (myql cell-type {data_type: varchar}) null
    assert equal (myql cell-type {data_type: longtext}) null
    # JSON is the per-engine divergence, so the shared layer does not touch it
    assert equal (myql cell-type {data_type: json}) null
}

@test
def "cell-type converters are null-safe" [] {
    assert equal (null | do (myql cell-type {data_type: int})) null
}

# ---- SELECT clause renderers --------------------------------------------------

@test
def "projection stars an empty column list" [] {
    assert equal (myql projection [] false) "SELECT *"
}

@test
def "projection comma-joins columns and honors distinct" [] {
    assert equal (myql projection [id name] false) "SELECT id, name"
    assert equal (myql projection [status] true) "SELECT DISTINCT status"
}

@test
def "order-term normalizes direction and passes bare exprs through" [] {
    assert equal (myql order-term "age desc") "age DESC"
    assert equal (myql order-term "created_at ASC") "created_at ASC"
    assert equal (myql order-term "name") "name"
    assert equal (myql order-term "   ") ""
}

@test
def "order composes a comma-separated ORDER BY, null when empty" [] {
    assert equal (myql order "salary desc, name asc") "ORDER BY salary DESC, name ASC"
    assert equal (myql order "name") "ORDER BY name"
    assert equal (myql order "") null
}

@test
def "lock renders FOR UPDATE and FOR SHARE with OF and wait policies" [] {
    assert equal (myql lock "update" [] false false) "FOR UPDATE"
    assert equal (myql lock "update" [] true false) "FOR UPDATE SKIP LOCKED"
    assert equal (myql lock "update" [] false true) "FOR UPDATE NOWAIT"
    assert equal (myql lock "share" [t1 t2] false false) "FOR SHARE OF t1, t2"
}

@test
def "lock renders the legacy LOCK IN SHARE MODE and null when unset" [] {
    assert equal (myql lock "share-mode" [] false false) "LOCK IN SHARE MODE"
    assert equal (myql lock null [] false false) null
}
