use std/assert
use std/testing *
use ../sql.nu

# ---- build-select -------------------------------------------------------------

@test
def "minimal select uses star and required from" [] {
    assert equal (sql build-select --from "users") "SELECT * FROM users"
}

@test
def "explicit columns are comma joined" [] {
    assert equal (sql build-select --columns ["id" "name"] --from "users") "SELECT id, name FROM users"
}

@test
def "full clause composition in order" [] {
    let actual = sql build-select --columns ["id"] --from "users" --where "age > 18" --sort-by "name" --limit 10
    assert equal $actual "SELECT id FROM users WHERE age > 18 ORDER BY name LIMIT 10"
}

@test
def "missing from errors" [] {
    assert error { sql build-select }
}

# ---- build-update / build-delete ----------------------------------------------

@test
def "build-update composes SET WHERE RETURNING in order" [] {
    assert equal (sql build-update --table users --set ["status = 'inactive'"] --where "id = 5") "UPDATE users SET status = 'inactive' WHERE id = 5"
    assert equal (sql build-update --table users --set ["a = 1" "b = b + 1"] --where "id = 5" --returning ["id" "b"]) "UPDATE users SET a = 1, b = b + 1 WHERE id = 5 RETURNING id, b"
}

@test
def "build-update drops an empty WHERE and empty RETURNING" [] {
    assert equal (sql build-update --table t --set ["x = 1"]) "UPDATE t SET x = 1"
}

@test
def "build-update requires a table and at least one assignment" [] {
    assert error { sql build-update --set ["x = 1"] }        # no table
    assert error { sql build-update --table t }              # no assignments
    assert error { sql build-update --table t --set [] }     # empty assignments
}

@test
def "build-delete composes WHERE and RETURNING, drops empties" [] {
    assert equal (sql build-delete --table sessions --where "expires_at < now()") "DELETE FROM sessions WHERE expires_at < now()"
    assert equal (sql build-delete --table sessions --where "id = 5" --returning ["*"]) "DELETE FROM sessions WHERE id = 5 RETURNING *"
    assert equal (sql build-delete --table sessions) "DELETE FROM sessions"
}

@test
def "build-delete requires a table" [] {
    assert error { sql build-delete --where "id = 1" }
}

# ---- generic assembly helpers -------------------------------------------------

@test
def "assemble drops empty and null fragments and space-joins" [] {
    assert equal (sql assemble ["SELECT *" "FROM t" null "" "LIMIT 5"]) "SELECT * FROM t LIMIT 5"
    assert equal (sql assemble []) ""
}

@test
def "join-list comma-joins with an optional prefix, null when empty" [] {
    assert equal (sql join-list [a b c]) "a, b, c"
    assert equal (sql join-list [a b] --prefix "GROUP BY ") "GROUP BY a, b"
    assert equal (sql join-list []) null
    assert equal (sql join-list ["" "x"]) "x"
}

@test
def "base-table strips an alias but keeps schema qualification" [] {
    assert equal (sql base-table "users u") "users"
    assert equal (sql base-table "public.users") "public.users"
    assert equal (sql base-table "  orders   o  ") "orders"
}

# ---- null-or ------------------------------------------------------------------

@test
def "null-or is dialect-agnostic: only a real null short-circuits" [] {
    let f = sql null-or {|x| $x | into int }
    assert equal (null | do $f) null    # a real null stays null
    assert equal ("42" | do $f) 42      # a value is converted
    # "" / "NULL" are NOT special here — the dialect's placeholder is turned into
    # a real null upstream (normalize-nulls / schema-body), so null-or never sees it.
}

@test
def "null-or applies the converter otherwise" [] {
    let f = sql null-or {|x| $x | into int }
    assert equal ("42" | do $f) 42
}

# ---- schema normalization -----------------------------------------------------

def raw-columns [] {
    [
        {schema: public, table: users, name: id, position: "1", data_type: integer, udt_name: int4, is_nullable: "NO", default: null, char_max_length: "", numeric_precision: "32", numeric_scale: "0", comment: "pk"}
        {schema: public, table: users, name: email, position: "2", data_type: "character varying", udt_name: varchar, is_nullable: "YES", default: "NULL", char_max_length: "255", numeric_precision: "", numeric_scale: "", comment: ""}
    ]
}

@test
def "normalize-columns coerces nullable, ints and injects display_type" [] {
    let cols = sql normalize-columns (raw-columns) {|c| $c.data_type } ["" "NULL"]
    assert equal $cols.0.nullable false
    assert equal $cols.1.nullable true
    assert equal $cols.0.position 1
    assert equal $cols.0.numeric_precision 32
    assert equal $cols.1.char_max_length 255
    assert equal $cols.1.default null      # literal "NULL" -> null
    assert equal $cols.0.display_type "integer"
    assert equal ("is_nullable" in ($cols.0 | columns)) false
}

@test
def "normalize-tables coerces row_estimate and nullifies comment" [] {
    let t = sql normalize-tables [{schema: public, name: users, type: "BASE TABLE", comment: "", row_estimate: "5"}] ["" "NULL"]
    assert equal $t.0.row_estimate 5
    assert equal $t.0.comment null
}

@test
def "normalize-constraints splits column lists" [] {
    let c = sql normalize-constraints [{schema: public, table: t, name: pk, type: "PRIMARY KEY", columns: "a,b", ref_schema: "NULL", ref_table: "NULL", ref_columns: "NULL"}] ["" "NULL"]
    assert equal $c.0.columns [a b]
    assert equal $c.0.ref_table null
    assert equal $c.0.ref_columns null
}

# ---- typing -------------------------------------------------------------------

def sample-data [] {
    {
        meta: {connection: c, database: d, driver: psql}
        tables: [{schema: public, name: users, type: "BASE TABLE", comment: null, row_estimate: 5}]
        columns: [
            {schema: public, table: users, name: id, position: 1, data_type: integer, display_type: int4, nullable: false, default: null, comment: null}
            {schema: public, table: users, name: name, position: 2, data_type: text, display_type: text, nullable: true, default: null, comment: null}
        ]
        constraints: [{schema: public, table: users, name: pk_users, type: "PRIMARY KEY", columns: [id], ref_schema: null, ref_table: null, ref_columns: null}]
    }
}

@test
def "columns-for resolves bare and qualified names" [] {
    assert equal (sql columns-for (sample-data) "users" | get name) [id name]
    assert equal (sql columns-for (sample-data) "public.users" | get name) [id name]
}

@test
def "apply-types coerces known columns and leaves the rest" [] {
    let rows = [{id: "1", name: "Ann"}, {id: "2", name: "Bo"}]
    let cols = sql columns-for (sample-data) "users"
    let conv = {|col| if $col.data_type == "integer" { sql null-or {|x| $x | into int } } else { null } }
    let typed = $rows | sql apply-types $cols $conv
    assert equal $typed.0.id 1
    assert equal $typed.0.name "Ann"
}

@test
def "apply-types ignores columns absent from the result" [] {
    let rows = [{id: "1"}]
    let cols = sql columns-for (sample-data) "users"
    let conv = {|col| sql null-or {|x| $x | into int } }
    let typed = $rows | sql apply-types $cols $conv
    assert equal $typed.0.id 1
}

@test
def "normalize-nulls maps blank and literal NULL to null across all columns" [] {
    let rows = [{name: "Ann", manager: ""}, {name: "Bo", manager: "NULL"}, {name: "Cy", manager: "Zed"}]
    let out = $rows | sql normalize-nulls ["" "NULL"]
    assert equal $out.0.manager null    # blank (postgres NULL rendering) → null
    assert equal $out.1.manager null    # literal "NULL" (mysql NULL rendering) → null
    assert equal $out.2.manager "Zed"   # a real value is kept
    assert equal $out.0.name "Ann"      # untouched column kept
}

@test
def "normalize-nulls is a no-op on an empty result" [] {
    assert equal ([] | sql normalize-nulls ["" "NULL"]) []
}

@test
def "normalize-nulls honors the injected placeholder set per dialect" [] {
    let rows = [{a: "", b: "NULL"}]
    let my = ($rows | sql normalize-nulls ["NULL"])   # mysql-style: only "NULL" is a NULL
    assert equal $my.0.a ""       # empty string kept — not a mysql NULL
    assert equal $my.0.b null     # literal NULL → null
    let pg = ($rows | sql normalize-nulls [""])       # postgres-style: only "" is a NULL
    assert equal $pg.0.a null     # empty field → null
    assert equal $pg.0.b "NULL"   # literal "NULL" string kept
}

# ---- schema display -----------------------------------------------------------

@test
def "schema-tables summarizes counts and primary key" [] {
    let s = sql schema-tables (sample-data)
    assert equal $s.0.columns 2
    assert equal $s.0.pk "id"
}

@test
def "schema-detail returns the matching table" [] {
    assert equal (sql schema-detail (sample-data) "users" | get name) "users"
}

@test
def "schema-detail errors on an unknown table" [] {
    assert error { sql schema-detail (sample-data) "nope" }
}

@test
def "schema-find matches names and comments case-insensitively" [] {
    assert equal (sql schema-find (sample-data) "ID" | where column == "id" | length) 1
    assert equal (sql schema-find (sample-data) "users" | where kind == "table" | length) 1
}

# ---- completion helpers -------------------------------------------------------

@test
def "parse-flag extracts flag values and returns null when absent" [] {
    assert equal (sql parse-flag "select --from public.users -c prod" ["--connection" "-c"]) "prod"
    assert equal (sql parse-flag "select --from public.users" ["--from" "-F"]) "public.users"
    assert equal (sql parse-flag "select" ["--connection" "-c"]) null
}

@test
def "lead-arg reads the table positional after a write verb" [] {
    assert equal (sql lead-arg 'mole-psql update users "a = 1" st' [update delete]) "users"
    assert equal (sql lead-arg "mole-psql delete sessions --where " [update delete]) "sessions"
    assert equal (sql lead-arg "mole-psql update public.users col" [update delete]) "public.users"
    # a flag in the slot, or no such verb (e.g. a select context) → null, so the caller falls back
    assert equal (sql lead-arg "mole-psql update -c prod " [update delete]) null
    assert equal (sql lead-arg "mole-psql select id --from users" [update delete]) null
}

@test
def "complete-tables and complete-columns read a cache record" [] {
    assert equal (sql complete-tables (sample-data)) ["public.users"]
    assert equal (sql complete-columns (sample-data) "users") [id name]
    assert equal (sql complete-tables {}) []
}

@test
def "complete-columns returns bare, unqualified names even without a table" [] {
    # no table (columns typed before --from) -> deduped bare names, never table.col
    assert equal (sql complete-columns (sample-data)) [id name]
    assert equal (sql complete-columns (sample-data) | any {|c| $c =~ '\.'}) false
}
