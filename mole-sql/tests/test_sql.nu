use std/assert
use std/testing *
use ../sql.nu

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

# ---- schema filtering ---------------------------------------------------------

# A multi-table fixture with a cross-table foreign key (orders.user_id → users.id),
# so the dangling-FK pruning has something to bite on.
def filter-data [] {
    {
        meta: {driver: psql}
        tables: [
            {schema: public, name: users,     type: "BASE TABLE", comment: null, row_estimate: 5}
            {schema: public, name: orders,    type: "BASE TABLE", comment: null, row_estimate: 9}
            {schema: public, name: audit_log, type: "BASE TABLE", comment: "housekeeping", row_estimate: 99}
        ]
        columns: [
            {schema: public, table: users,     name: id,      nullable: false}
            {schema: public, table: orders,    name: id,      nullable: false}
            {schema: public, table: orders,    name: user_id, nullable: false}
            {schema: public, table: audit_log, name: id,      nullable: false}
        ]
        constraints: [
            {schema: public, table: users,  name: users_pk, type: "PRIMARY KEY", columns: [id], ref_schema: null, ref_table: null, ref_columns: null}
            {schema: public, table: orders, name: orders_users_fk, type: "FOREIGN KEY", columns: [user_id], ref_schema: public, ref_table: users, ref_columns: [id]}
        ]
    }
}

@test
def "schema-filter with no patterns returns data untouched" [] {
    assert equal (sql schema-filter (filter-data)) (filter-data)
}

@test
def "schema-filter --include keeps just the listed tables and prunes their columns" [] {
    let r = (sql schema-filter (filter-data) --include [users])
    assert equal ($r.tables | get name) [users]
    assert equal ($r.columns | get table | uniq) [users]
    assert equal ($r.meta.driver) "psql"   # extra top-level keys survive
}

@test
def "schema-filter --exclude drops matching tables, glob patterns included" [] {
    assert equal (sql schema-filter (filter-data) --exclude ["*_log"] | get tables.name) [users orders]
    assert equal (sql schema-filter (filter-data) --exclude [audit_log] | get tables.name) [users orders]
}

@test
def "schema-filter drops a FK whose referenced table was pruned away" [] {
    # keep orders, drop users → the orders→users FK would dangle; it must be removed
    let r = (sql schema-filter (filter-data) --include [orders])
    assert equal ($r.tables | get name) [orders]
    assert equal ($r.constraints | length) 0
}

@test
def "schema-filter keeps an FK when both endpoints survive" [] {
    let r = (sql schema-filter (filter-data) --include [users orders])
    assert equal ($r.constraints | where type == "FOREIGN KEY" | length) 1
}

@test
def "schema-filter applies exclude after include, so exclude wins on overlap" [] {
    let r = (sql schema-filter (filter-data) --include [users orders] --exclude [orders])
    assert equal ($r.tables | get name) [users]
}

@test
def "schema-filter matches qualified patterns against schema and name" [] {
    assert equal (sql schema-filter (filter-data) --include ["public.orders"] | get tables.name) [orders]
    # a wrong schema qualifier matches nothing
    assert equal (sql schema-filter (filter-data) --include ["other.orders"] | get tables.name) []
}

# ---- completion helpers -------------------------------------------------------

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

# ---- predicate tokens ---------------------------------------------------------

@test
def "predicate-token parses operator tokens and rejects projections" [] {
    assert equal (sql predicate-token "status=active") {col: status, op: "=", value: active}
    assert equal (sql predicate-token "age>=30") {col: age, op: ">=", value: "30"}   # longest-first: >= not >
    assert equal (sql predicate-token "age<10") {col: age, op: "<", value: "10"}
    assert equal (sql predicate-token "name~%a%") {col: name, op: "~", value: "%a%"}
    assert equal (sql predicate-token "name!~%a%") {col: name, op: "!~", value: "%a%"}
    assert equal (sql predicate-token "t.col!=x") {col: "t.col", op: "!=", value: x}   # dotted column
    # projections / bare tokens carry no operator
    assert equal (sql predicate-token "id") null
    assert equal (sql predicate-token "count(*) AS n") null
}

@test
def "sql-literal quotes by value shape and escapes backslash per dialect" [] {
    assert equal (sql sql-literal "active") "'active'"
    assert equal (sql sql-literal "30") "30"
    assert equal (sql sql-literal "-3.5") "-3.5"
    assert equal (sql sql-literal "01234") "'01234'"     # leading zero ⇒ a code, not a number
    assert equal (sql sql-literal "0") "0"
    assert equal (sql sql-literal "0.5") "0.5"
    assert equal (sql sql-literal "true") "true"
    assert equal (sql sql-literal "False") "false"
    assert equal (sql sql-literal "O'Brien") "'O''Brien'"
    # signed, scientific and leading-dot numeric forms are numbers too (B3)
    assert equal (sql sql-literal "+5") "+5"
    assert equal (sql sql-literal ".5") ".5"
    assert equal (sql sql-literal "1e5") "1e5"
    assert equal (sql sql-literal "2.5E-3") "2.5E-3"
    assert equal (sql sql-literal "+01") "'+01'"      # leading zero still a code
    assert equal (sql sql-literal "5.") "'5.'"
    # backslash: LITERAL by default (psql/trino/duckdb); DOUBLED where the dialect
    # treats `\` as an escape char (mysql/mariadb). Single-quoted nu strings are raw,
    # so 'a\b' is a,\,b and 'a\\b' is a,\,\,b.
    let q = "'"
    assert equal (sql sql-literal 'a\b') ($q + 'a\b' + $q)                                 # default: 'a\b'
    assert equal (sql sql-literal 'a\b' {backslash_escapes: true}) ($q + 'a\\b' + $q)      # mysql:   'a\\b'
    assert equal (sql sql-literal "O'Brien" {backslash_escapes: true}) "'O''Brien'"        # quote-doubling still applies
}

@test
def "render-predicate covers every operator form" [] {
    assert equal (sql render-predicate {col: status, op: "=", value: active}) "status = 'active'"
    assert equal (sql render-predicate {col: age, op: ">=", value: "30"}) "age >= 30"
    assert equal (sql render-predicate {col: x, op: "!=", value: y}) "x <> 'y'"           # != → <>
    assert equal (sql render-predicate {col: deleted, op: "=", value: "null"}) "deleted IS NULL"
    assert equal (sql render-predicate {col: deleted, op: "!=", value: "null"}) "deleted IS NOT NULL"
    assert equal (sql render-predicate {col: role, op: "=", value: "in:admin,ops"}) "role IN ('admin', 'ops')"
    assert equal (sql render-predicate {col: role, op: "!=", value: "in:a,b"}) "role NOT IN ('a', 'b')"
    assert equal (sql render-predicate {col: name, op: "~", value: "%acme%"}) "name LIKE '%acme%'"
    assert equal (sql render-predicate {col: name, op: "!~", value: "%acme%"}) "name NOT LIKE '%acme%'"
}

@test
def "operators are injected: a dialect ops table renders via symbol/keyword/function/null-safe primitives" [] {
    assert equal (sql ansi-ops | get token) ["=" "!=" ">=" "<=" ">" "<" "~" "!~"]   # the shared base (~ = LIKE, universal)
    # a driver extends the base with dialect operators rendered four ways — a keyword
    # (ILIKE via render-like), a function call (regex via render-func), and a null-safe
    # comparator (render-nullsafe). These closures are DEFINED here (test module) and
    # INVOKED inside mole-sql's render-predicate — the cross-module case drivers rely on.
    let ops = (sql ansi-ops
      | append {token: "~*",  desc: "ILIKE",      render: {|c, v, lit| sql render-like "ILIKE" $c $v $lit }}
      | append {token: "!~*", desc: "NOT ILIKE",  render: {|c, v, lit| sql render-like "NOT ILIKE" $c $v $lit }}
      | append {token: "=~",  desc: "regex",      render: {|c, v, lit| sql render-func "regexp_like" $c $v $lit }}
      | append {token: "!=~", desc: "not regex",  render: {|c, v, lit| "NOT " + (sql render-func "regexp_like" $c $v $lit) }}
      | append {token: "<=>", desc: "null-safe",  render: {|c, v, lit| sql render-nullsafe "<=>" $c $v $lit }})
    # parse: longest-first precedence — ~* beats ~; =~ beats =; !=~ beats != ; <=> beats <= beats <
    assert equal (sql predicate-token "name~*acme" --ops $ops) {col: name, op: "~*", value: acme}
    assert equal (sql predicate-token "name~acme"  --ops $ops) {col: name, op: "~", value: acme}
    assert equal (sql predicate-token "a=~^x"  --ops $ops) {col: a, op: "=~", value: "^x"}
    assert equal (sql predicate-token "a=5"    --ops $ops) {col: a, op: "=", value: "5"}
    assert equal (sql predicate-token "a!=~^x" --ops $ops) {col: a, op: "!=~", value: "^x"}
    assert equal (sql predicate-token "a!=5"   --ops $ops) {col: a, op: "!=", value: "5"}
    assert equal (sql predicate-token "a<=>b"  --ops $ops) {col: a, op: "<=>", value: b}
    assert equal (sql predicate-token "a<=5"   --ops $ops) {col: a, op: "<=", value: "5"}
    # render: keyword form (ILIKE), function form (regexp_like), null-safe (bare NULL on null value)
    assert equal (sql render-predicate {col: name, op: "~*", value: acme} --ops $ops) "name ILIKE 'acme'"
    assert equal (sql render-predicate {col: name, op: "=~", value: "^a"} --ops $ops) "regexp_like(name, '^a')"
    assert equal (sql render-predicate {col: name, op: "!=~", value: "^a"} --ops $ops) "NOT regexp_like(name, '^a')"
    assert equal (sql render-predicate {col: a, op: "<=>", value: b} --ops $ops) "a <=> 'b'"
    assert equal (sql render-predicate {col: a, op: "<=>", value: "null"} --ops $ops) "a <=> NULL"
    assert equal (sql render-predicate {col: name, op: "~", value: acme} --ops $ops) "name LIKE 'acme'"   # base ~ still LIKE
    # build-where threads the SAME injected ops end-to-end
    assert equal (sql build-where "status=active,name=~^a" --ops $ops) "status = 'active' AND regexp_like(name, '^a')"
}

@test
def "regex-escape shields operator metacharacters" [] {
    assert equal (sql regex-escape "~*") '~\*'
    assert equal (sql regex-escape "<=>") "<=>"       # no regex metacharacters
    assert equal (sql regex-escape "a.b") 'a\.b'
}

@test
def "op-completions offers col<op> with descriptions" [] {
    let cs = (sql op-completions "status" (sql ansi-ops))
    assert equal ($cs | first) {value: "status=", description: equals}
    assert equal ($cs | get value) ["status=" "status!=" "status>=" "status<=" "status>" "status<" "status~" "status!~"]
}

@test
def "parse-where parses a token-list and errors on anything else" [] {
    assert equal (sql parse-where "status=active,age>=30") [{col: status, op: "=", value: active} {col: age, op: ">=", value: "30"}]
    assert equal (sql parse-where "role=in:admin,ops") [{col: role, op: "=", value: "in:admin,ops"}]   # in: list folds back over the comma
    assert equal (sql parse-where "status=active,role=in:a,b,age>=1") [{col: status, op: "=", value: active} {col: role, op: "=", value: "in:a,b"} {col: age, op: ">=", value: "1"}]
    assert equal (sql parse-where "") []                                    # empty ⇒ no predicates
    assert error { sql parse-where "status = 'active' AND age > 5" }        # raw SQL is not a token-list: it belongs in --where-sql
    assert error { sql parse-where "(a OR b) AND c" }
}

@test
def "render-predicate treats the value as a literal and rejects pasted SQL" [] {
    # a tight first operator makes raw SQL parse as ONE token; the connective inside the value gives it away
    assert error { sql build-where "a=1 AND b=2" }                          # used to render a = '1 AND b=2'
    assert error { sql build-where "id=7 OR 1=1" }                          # used to return row 7 on MySQL
    assert error { sql build-where "total>0 AND status<>'void'" }
    assert error { sql build-where "a=1 and b=2" }                          # case-insensitive
    assert equal (sql build-where "created_at>now()") "created_at > 'now()'"      # the RHS is a literal by definition; a function belongs in --where-sql
    assert equal (sql build-where "a=b") "a = 'b'"                                 # likewise a column name
    # quoting the value makes it a literal unconditionally
    assert equal (sql build-where "status='active'") "status = 'active'"           # not '''active'''
    assert equal (sql build-where "zip='30'") "zip = '30'"                         # not the bare number 30
    assert equal (sql build-where "note='a and b'") "note = 'a and b'"             # the connective check is skipped
    assert equal (sql build-where "note=\"it's\"") "note = 'it''s'"                 # inner quote still doubled
    assert equal (sql build-where "x='") "x = ''''"                                # a lone quote is a one-char value, not a wrapper
}

@test
def "parse-where trims items and drops blank ones" [] {
    assert equal (sql parse-where "a=1, b=2") (sql parse-where "a=1,b=2")             # a space after the comma starts a new predicate
    assert equal (sql parse-where "status=active,") (sql parse-where "status=active")  # a trailing comma is not part of the value
    assert equal (sql parse-where "a=1,,b=2") (sql parse-where "a=1,b=2")              # nor is a doubled one
    assert equal (sql parse-where ",") []                                               # all blank ⇒ no predicates (the --all guard fires)
    assert equal (sql parse-where "role=in:a, b") [{col: role, op: "=", value: "in:a,b"}]   # an in: continuation still folds
    assert error { sql parse-where "name=Smith, John" }                                 # a non-token after a non-in: predicate is an error, not a value
}

@test
def "an empty in: list errors instead of rendering an empty IN" [] {
    assert error { sql build-where "role=in:" }
    assert error { sql build-where "role!=in:," }
}

@test
def "render-where AND-joins predicate records" [] {
    assert equal (sql render-where [{col: status, op: "=", value: active} {col: age, op: ">=", value: "30"}]) "status = 'active' AND age >= 30"
    assert equal (sql render-where []) null
    let q = "'"
    assert equal (sql render-where [{col: path, op: "=", value: 'a\b'}] --dialect {backslash_escapes: true}) ("path = " + $q + 'a\\b' + $q)   # dialect escaping threads through
}

@test
def "build-where renders tokens, passes raw SQL verbatim, AND-joins both" [] {
    assert equal (sql build-where "status=active,age>=30") "status = 'active' AND age >= 30"
    assert equal (sql build-where "role=in:admin,ops") "role IN ('admin', 'ops')"
    assert equal (sql build-where "deleted=null") "deleted IS NULL"
    assert equal (sql build-where "name~%John Smith%") "name LIKE '%John Smith%'"   # a space in the VALUE is fine
    assert equal (sql build-where null "created_at > now() - interval '1 day'") "created_at > now() - interval '1 day'"
    assert equal (sql build-where "" "id = 42") "id = 42"
    assert equal (sql build-where "status=active" "a > 1 OR b") "(status = 'active') AND (a > 1 OR b)"
    assert equal (sql build-where "" "") null
    assert equal (sql build-where null null) null
    assert equal (sql build-where "," " ") null                                  # blanks on both sides ⇒ no filter
    assert error { sql build-where "id = 42" }                                   # raw SQL in the token slot is an error, never a guess
    # the structured side threads INJECTED dialect ops (regex → function form)
    let ops = (sql ansi-ops | append {token: "=~", desc: "regex", render: {|c, v, lit| sql render-func "regexp_like" $c $v $lit }})
    assert equal (sql build-where "name=~^a" --ops $ops) "regexp_like(name, '^a')"
}

@test
def "sort-token parses col and optional direction" [] {
    assert equal (sql sort-token "created_at") {col: "created_at", dir: ""}
    assert equal (sql sort-token "amount:desc") {col: "amount", dir: "DESC"}
    assert equal (sql sort-token "name:asc") {col: "name", dir: "ASC"}
    assert equal (sql sort-token "") null
    assert equal (sql sort-token "amount:DESC") {col: "amount", dir: "DESC"}    # case-insensitive
    assert error { sql sort-token "amount:dsc" }                                  # a typo must not silently sort ascending
    assert error { sql sort-token ":desc" }                                       # no column must not silently drop the term
    assert error { sql sort-token "amount desc" }                                 # raw SQL is not a sort token
    assert error { sql sort-token "id; DROP TABLE t" }
    assert equal (sql sort-token "t.col:desc") {col: "t.col", dir: "DESC"}        # dotted identifiers are fine
}

@test
def "build-order renders sort tokens or null" [] {
    assert equal (sql build-order ["region" "amount:desc"]) "ORDER BY region, amount DESC"
    assert equal (sql build-order ["id"]) "ORDER BY id"
    assert equal (sql build-order []) null
}

@test
def "sanitize-name flattens non-word chars" [] {
    assert equal (sql sanitize-name "order.total") "order_total"
    assert equal (sql sanitize-name "a b") "a_b"
}

@test
def "build-aggs expands requests into SQL-like named specs" [] {
    assert equal (sql build-aggs [{fn: "count"} {fn: "sum", cols: [amount]}]) [{expr: "count(*)", name: "count", type: "int"} {expr: "sum(amount)", name: "sum_amount", type: "float"}]
    assert equal (sql build-aggs []) [{expr: "count(*)", name: "count", type: "int"}]                 # empty → default count(*)
    assert equal (sql build-aggs [{fn: "count-distinct", cols: [customer.id]}]) [{expr: "count(distinct customer.id)", name: "count_distinct_customer_id", type: "int"}]
    assert equal (sql build-aggs [{fn: "count"} {fn: "sum", cols: [x]} {fn: "avg", cols: [y]} {fn: "max", cols: [z]}] | get name) ["count" "sum_x" "avg_y" "max_z"]   # request order preserved
    assert equal (sql build-aggs [{fn: "min", cols: [ts]}] | first | get type) null                   # min/max carry no type
    # a driver's INJECTED dialect aggregate renders via its own closure (string_agg here) and
    # carries its own type (median → float)
    let aggs = (sql ansi-aggs
      | append {flag: "string_agg", fieldless: false, render: {|col| $"string_agg\(($col), ','\)" }}
      | append {flag: "median", fieldless: false, type: "float", render: {|col| $"median\(($col)\)" }})
    assert equal (sql build-aggs [{fn: "string_agg", cols: [tags]}] $aggs) [{expr: "string_agg(tags, ',')", name: "string_agg_tags", type: null}]
    assert equal (sql build-aggs [{fn: "median", cols: [amount]}] $aggs) [{expr: "median(amount)", name: "median_amount", type: "float"}]
}

@test
def "result-cols lists the group keys then the aggregate names" [] {
    assert equal (sql result-cols [region] {count: true, sum: [amount]}) [region count sum_amount]
    assert equal (sql result-cols [] {}) [count]                                                      # the default count(*)
    let aggs = (sql ansi-aggs | append {flag: "string-agg", fieldless: false, render: {|c| "" }})
    assert equal (sql result-cols [a b] {"string-agg": [name], count: true} $aggs) [a b count string_agg_name]
}

@test
def "build-having expands aliases to expressions and count is always available" [] {
    assert equal (sql build-having ["sum_amount>=1000"] [{expr: "sum(amount)", name: "sum_amount"}]) "HAVING sum(amount) >= 1000"
    assert equal (sql build-having ["count>5"] []) "HAVING count(*) > 5"                            # count without --count
    assert equal (sql build-having ["sum_amount>1" "count>=2"] [{expr: "sum(amount)", name: "sum_amount"}]) "HAVING sum(amount) > 1 AND count(*) >= 2"
    assert equal (sql build-having []) null
}

@test
def "agg-requests drops a repeated column so result names stay unique" [] {
    assert equal (sql agg-requests {sum: [amount amount b]}) [{fn: sum, cols: [amount b]}]
    assert equal (sql result-cols [] {sum: [amount amount]}) [sum_amount]
}

@test
def "build-having errors on a token it cannot parse" [] {
    assert error { sql build-having ["count >= 10"] [] }                         # spaced ⇒ not a predicate; dropping it would unfilter
    assert error { sql build-having ["count>=1" "sum_amount"] [{expr: "sum(amount)", name: "sum_amount"}] }
}

@test
def "apply-agg-types coerces aggregate columns by their declared type" [] {
    let table = (sql ansi-aggs | append {flag: "median", fieldless: false, type: "float", render: {|col| $"median\(($col)\)" }})
    let aggs = (sql build-aggs [{fn: "count"} {fn: "avg", cols: [amount]} {fn: "sum", cols: [x]} {fn: "min", cols: [ts]} {fn: "median", cols: [amount]}] $table)
    let out = ([{count: "3", avg_amount: "4.5", sum_x: "10", min_ts: "2024-01-01", median_amount: "7.5"}] | sql apply-agg-types $aggs | first)
    assert equal $out.count 3            # count → int
    assert equal $out.avg_amount 4.5     # avg → float
    assert equal $out.sum_x 10.0         # sum → float
    assert equal $out.min_ts "2024-01-01"   # min/max untouched (schema types them)
    assert equal $out.median_amount 7.5  # a dialect extra types itself from the table
    assert equal ([{count: null}] | sql apply-agg-types (sql build-aggs []) | first | get count) null   # null stays null
}

@test
def "render-predicate and render-where forward the dialect escaping" [] {
    let q = "'"
    # a backslash value: default leaves it literal; the mysql spec doubles it
    assert equal (sql render-predicate {col: path, op: "=", value: 'a\b'}) ("path = " + $q + 'a\b' + $q)
    assert equal (sql render-predicate {col: path, op: "=", value: 'a\b'} {backslash_escapes: true}) ("path = " + $q + 'a\\b' + $q)
    # render-where threads the dialect down to each predicate's literal
    assert equal (sql render-where [{col: path, op: "=", value: 'a\b'}] --dialect {backslash_escapes: true}) ("path = " + $q + 'a\\b' + $q)
    assert equal (sql render-where [{col: path, op: "=", value: 'a\b'}]) ("path = " + $q + 'a\b' + $q)
}

# ---- where-clause / where-plan ------------------------------------------------

@test
def "where-clause wraps the body or drops it" [] {
    assert equal (sql where-clause "status=active,age>=30") "WHERE status = 'active' AND age >= 30"
    assert equal (sql where-clause null "a > 1 OR b") "WHERE a > 1 OR b"
    assert equal (sql where-clause "status=active" "a > 1 OR b") "WHERE (status = 'active') AND (a > 1 OR b)"
    assert equal (sql where-clause "") null
    assert equal (sql where-clause null) null
}

@test
def "where-plan stage one offers columns with the committed prefix" [] {
    assert equal (sql where-plan "na" [id name status]) {candidates: [id name status]}
    assert equal (sql where-plan "status=active,na" [id name status]) {candidates: ["status=active,id" "status=active,name" "status=active,status"]}
}

@test
def "where-plan stage two offers the dialect operators plus longer columns" [] {
    let plan = (sql where-plan "status" [status status_code])
    assert equal ($plan.candidates | first) {value: "status=", description: "equals"}
    assert equal ($plan.candidates | last) {value: "status_code", description: "column"}
    assert equal ($plan.candidates | where value == "status~*" | length) 0   # ANSI ops only by default
    let pg = (sql where-plan "status" [status] --ops ((sql ansi-ops) ++ [{token: "~*", desc: "ILIKE", render: {|c, v, l| "" }}]))
    assert equal ($pg.candidates | where value == "status~*" | length) 1
}

@test
def "where-plan stage three is a probe scoped to the sibling predicates" [] {
    assert equal (sql where-plan "role=" [role] --table users) {probe: {sql: "SELECT DISTINCT role AS v FROM users LIMIT 50", prefix: "role="}}
    assert equal (sql where-plan "status=active,role!=" [role status] --table users) {probe: {sql: "SELECT DISTINCT role AS v FROM users WHERE status = 'active' LIMIT 50", prefix: "status=active,role!="}}
    # the probed column's own earlier predicate is not used to scope itself
    assert equal (sql where-plan "role=admin,role=" [role] --table users).probe.sql "SELECT DISTINCT role AS v FROM users LIMIT 50"
}

@test
def "where-plan completes nothing for comparisons, in lists, open in lists, or no table" [] {
    assert equal (sql where-plan "age>=" [age] --table t) {candidates: []}
    assert equal (sql where-plan "role=in:a" [role] --table t) {candidates: []}
    assert equal (sql where-plan "role=in:admin,op" [role status] --table t) {candidates: []}
    assert equal (sql where-plan "role=" [role]) {candidates: []}
}

# ---- type-rows / schema-view / agg-requests -----------------------------------

@test
def "type-rows normalizes nulls and types the base table columns" [] {
    let data = {columns: [{schema: public, table: users, name: id, data_type: integer}]}
    let typer = {|c| if $c.data_type == "integer" { sql null-or {|x| $x | into int } } else { null } }
    assert equal ([{id: "1", note: "NULL"}] | sql type-rows $data "users u" ["NULL"] $typer) [{id: 1, note: null}]
    assert equal ([] | sql type-rows $data "users" ["NULL"] $typer) []
}

@test
def "schema-view dispatches full find table and summary" [] {
    let data = {
        tables: [{schema: public, name: users, type: "BASE TABLE", comment: null, row_estimate: 5}]
        columns: [{schema: public, table: users, name: id, position: 1, display_type: int4, nullable: false, default: null, comment: "pk"}]
        constraints: []
    }
    assert equal (sql schema-view $data --full) $data
    assert equal (sql schema-view $data --find pk | get kind) ["column-comment"]
    assert equal (sql schema-view $data --table users | get name) "users"
    assert equal (sql schema-view $data | get name) [users]
}

@test
def "agg-requests walks the aggs table in order" [] {
    assert equal (sql agg-requests {count: true, sum: [amount], avg: []}) [{fn: "count"} {fn: "sum", cols: [amount]}]
    assert equal (sql agg-requests {sum: [a b], count: true} | get fn) ["count" "sum"]   # table order, not flag order
    assert equal (sql agg-requests {}) []
    let aggs = ((sql ansi-aggs) ++ [{flag: "string-agg", fieldless: false, render: {|c| "" }}])
    assert equal (sql agg-requests {"string-agg": [name]} $aggs) [{fn: "string-agg", cols: [name]}]
}

@test
def "render-predicate rejects a value that starts with an operator character" [] {
    # `a==1` / `a=>1` / `a!==1` are typo'd operators, not literals — never `a = '=1'`
    assert error { sql render-where (sql parse-where "a==1") }
    assert error { sql render-where (sql parse-where "a=>1") }
    assert error { sql render-where (sql parse-where "a!==1") }
    assert error { sql render-where (sql parse-where "name~~x") }
    # quoting the value means it literally
    assert equal (sql render-where (sql parse-where "a='=1'")) "a = '=1'"
}

@test
def "build-having only accepts group keys and requested aggregate aliases" [] {
    let aggs = [{expr: "sum(amount)", name: sum_amount}]
    assert equal (sql build-having ["sum_amount>1"] $aggs --by [region]) "HAVING sum(amount) > 1"
    assert equal (sql build-having ["region=eu"] $aggs --by [region]) "HAVING region = 'eu'"
    assert equal (sql build-having ["count>=10"] [] --by [region]) "HAVING count(*) >= 10"   # count is always available
    assert error { sql build-having ["avg_amount>1"] $aggs --by [region] }                  # no --avg was requested
    assert error { sql build-having ["amount>1"] $aggs --by [region] }                      # a source column is not a result column
}

@test
def "page-clause renders validated LIMIT and OFFSET" [] {
    assert equal (sql page-clause 5 10) "LIMIT 5 OFFSET 10"
    assert equal (sql page-clause 5 10 --offset-first) "OFFSET 10 LIMIT 5"
    assert equal (sql page-clause 5 null) "LIMIT 5"
    assert equal (sql page-clause null 10) "OFFSET 10"
    assert equal (sql page-clause null null) null
    assert equal (sql page-clause 0 0) "LIMIT 0 OFFSET 0"
    assert error { sql page-clause (-1) null }
    assert error { sql page-clause 5 (-1) }
}

# ---- insert / update: build / literals / assignment tokens / plan -------------

@test
def "build-insert composes modifier tail and returning in order" [] {
    assert equal (sql build-insert --table users --columns [email status] --rows [["'a@b.c'" "'active'"]]) "INSERT INTO users (email, status) VALUES ('a@b.c', 'active')"
    assert equal (sql build-insert --table t --columns [a] --rows [["1"] ["2"]] --tail "ON CONFLICT DO NOTHING" --returning [id]) "INSERT INTO t (a) VALUES (1), (2) ON CONFLICT DO NOTHING RETURNING id"
    assert equal (sql build-insert --table t --columns [a b] --rows [["1" "2"]] --modifier IGNORE) "INSERT IGNORE INTO t (a, b) VALUES (1, 2)"
}

@test
def "build-insert validates its shape" [] {
    assert error { sql build-insert --columns [a] --rows [["1"]] }                 # no table
    assert error { sql build-insert --table t --rows [["1"]] }                     # no columns
    assert error { sql build-insert --table t --columns [a] }                      # no rows
    assert error { sql build-insert --table t --columns [a b] --rows [["1"]] }     # a narrow row
}

@test
def "value-literal renders by nushell type" [] {
    assert equal (sql value-literal null) "NULL"
    assert equal (sql value-literal true) "true"
    assert equal (sql value-literal 3) "3"
    assert equal (sql value-literal 2.5) "2.5"
    assert equal (sql value-literal "30") "'30'"                    # a typed string is never a number
    assert equal (sql value-literal "O'Brien") "'O''Brien'"
    assert equal (sql value-literal 'a\b' {backslash_escapes: true}) "'a\\\\b'"
    assert equal (sql value-literal {a: 1}) "'{\"a\":1}'"
    assert equal (sql value-literal [1 2]) "'[1,2]'"
    assert equal (sql value-literal ("2024-01-02T03:04:05+00:00" | into datetime)) "'2024-01-02T03:04:05+00:00'"
    assert equal (sql value-literal 3hr) "'3hr'"
}

@test
def "assignment-token parses col=value only" [] {
    assert equal (sql assignment-token "status=active") {col: status, value: active}
    assert equal (sql assignment-token "t.col=") {col: "t.col", value: ""}
    assert equal (sql assignment-token "a==1") {col: a, value: "=1"}   # parses; token-literal rejects it
    assert equal (sql assignment-token "age>=30") null
    assert equal (sql assignment-token "age!=30") null
    assert equal (sql assignment-token "id") null
    assert equal (sql assignment-token "1=2") null
}

@test
def "token-literal applies the token literal rules" [] {
    assert equal (sql token-literal "active") "'active'"
    assert equal (sql token-literal "30") "30"
    assert equal (sql token-literal "'30'") "'30'"
    assert equal (sql token-literal '"01234"') "'01234'"
    assert equal (sql token-literal "null") "NULL"
    assert equal (sql token-literal "NULL") "NULL"
    assert equal (sql token-literal "'null'") "'null'"                 # quoted ⇒ the string
    assert equal (sql token-literal "true") "true"
    assert equal (sql token-literal "Tom and Jerry") "'Tom and Jerry'"   # no raw-SQL guess in an assignment
    assert equal (sql token-literal 'a\b' {backslash_escapes: true}) "'a\\\\b'"
    assert error { sql token-literal "=1" }
    assert error { sql token-literal ">1" }
}

@test
def "parse-assignments rejects non-tokens and duplicates" [] {
    assert equal (sql parse-assignments [email=a@b.c status=active]) [{col: email, value: "a@b.c"} {col: status, value: active}]
    assert equal (sql parse-assignments []) []
    assert error { sql parse-assignments ["age>=30"] }
    assert error { sql parse-assignments ["a = 1"] }
    assert error { sql parse-assignments [a=1 a=2] }
}

@test
def "insert-values makes one row from tokens and expressions" [] {
    assert equal (sql insert-values null --assignments [email=a@b.c age=30]) {columns: [email age], values: [["'a@b.c'" "30"]]}
    assert equal (sql insert-values null --values-sql {at: "now()"}) {columns: [at], values: [["now()"]]}
    assert equal (sql insert-values null --assignments [a=1] --values-sql {at: "now()"}) {columns: [a at], values: [["1" "now()"]]}
}

@test
def "insert-values renders piped rows by type and appends constants" [] {
    let r = (sql insert-values [{sku: A1, qty: 3} {sku: B2, qty: null}] --assignments [src=import] --values-sql {at: "now()"})
    assert equal $r {columns: [sku qty src at], values: [["'A1'" "3" "'import'" "now()"] ["'B2'" "NULL" "'import'" "now()"]]}
    assert equal (sql insert-values {n: "30"}) {columns: [n], values: [["'30'"]]}        # one piped record is one row
    assert equal (sql insert-values [{s: 'a\b'}] --dialect {backslash_escapes: true}) {columns: [s], values: [["'a\\\\b'"]]}
}

@test
def "insert-values refuses nothing ragged rows non-records and clashes" [] {
    assert error { sql insert-values null }
    assert error { sql insert-values [] }
    assert error { sql insert-values "a,b" }                                               # not records
    assert error { sql insert-values [1 2] }                                               # not records
    assert error { sql insert-values [{a: 1} {b: 2}] }                                     # ragged
    assert error { sql insert-values [{a: 1} {a: 1, b: 2}] }                               # ragged (extra key)
    assert error { sql insert-values [{a: 1}] --assignments [a=2] }                        # piped + token
    assert error { sql insert-values null --assignments [a=2] --values-sql {a: "1"} }      # token + expr
    assert error { sql insert-values null --assignments [a=1 a=2] }                        # token twice
    assert error { sql insert-values null --assignments ["a = 1"] }                        # not a token
}

@test
def "render-assignments builds the update SET list" [] {
    assert equal (sql render-assignments [status=inactive age=30 note=null]) ["status = 'inactive'" "age = 30" "note = NULL"]
    assert equal (sql render-assignments [status=inactive] --values-sql {hits: "hits + 1"}) ["status = 'inactive'" "hits = hits + 1"]
    assert equal (sql render-assignments [] --values-sql {at: "now()"}) ["at = now()"]
    assert equal (sql render-assignments ['s=a\b'] --dialect {backslash_escapes: true}) ["s = 'a\\\\b'"]
    assert error { sql render-assignments [] }                                     # nothing to set
    assert error { sql render-assignments ["a = 1"] }                              # raw SQL is not a token
    assert error { sql render-assignments [a=1 a=2] }                              # assigned twice
    assert error { sql render-assignments [a=1] --values-sql {a: "2"} }            # token + expr
    assert error { sql render-assignments [a==1] }                                 # operator-looking value
}

@test
def "conflict-tail renders the ansi on conflict clause" [] {
    assert equal (sql conflict-tail --columns [a]) ""
    assert equal (sql conflict-tail --ignore --columns [a]) "ON CONFLICT DO NOTHING"
    assert equal (sql conflict-tail --upsert [email] --columns [email status]) "ON CONFLICT (email) DO UPDATE SET status = EXCLUDED.status"
    assert equal (sql conflict-tail --upsert [a b] --columns [a b c]) "ON CONFLICT (a, b) DO UPDATE SET c = EXCLUDED.c"
    assert equal (sql conflict-tail --upsert [email] --columns [email]) "ON CONFLICT (email) DO NOTHING"   # nothing left to SET
    assert error { sql conflict-tail --ignore --upsert [a] --columns [a] }
}

@test
def "assign-plan offers unassigned columns then a value probe" [] {
    let cols = [
      {name: id, display_type: integer, nullable: false, default: "nextval('s')"}
      {name: email, display_type: text, nullable: false, default: null}
      {name: note, display_type: text, nullable: true, default: null}
    ]
    assert equal (sql assign-plan "" $cols --required | get candidates) [{value: "id=", description: integer} {value: "email=", description: "text, required"} {value: "note=", description: text}]
    assert equal (sql assign-plan "em" $cols --assigned [id] --required | get candidates) [{value: "email=", description: "text, required"} {value: "note=", description: text}]
    assert equal (sql assign-plan "" $cols --assigned [id note] | get candidates) [{value: "email=", description: text}]   # update: no required flag
    assert equal (sql assign-plan "" [{name: status}] | get candidates) [{value: "status=", description: ""}]
    assert equal (sql assign-plan "email=" $cols --table users) {probe: {sql: "SELECT DISTINCT email AS v FROM users LIMIT 50", prefix: "email="}}
    assert equal (sql assign-plan "email=a" $cols --table users | get probe.prefix) "email="
    assert equal (sql assign-plan "email=" $cols) {candidates: []}                 # no table → no probe
    assert equal (sql assign-plan "nope=" $cols --table users) {candidates: []}    # unknown column
    assert equal (sql assign-plan "a=" [] --table users) {candidates: []}          # unknown table
    let names = ([status] | each {|x| $x })
    assert error { sql assign-plan "" $names }                                     # bare names are not column records
}

@test
def "unwrap-quoted reads matching quotes only" [] {
    assert equal (sql unwrap-quoted "'30'") {quoted: true, value: "30"}
    assert equal (sql unwrap-quoted '"a b"') {quoted: true, value: "a b"}
    assert equal (sql unwrap-quoted "'") {quoted: false, value: "'"}
    assert equal (sql unwrap-quoted "'a\"") {quoted: false, value: "'a\""}
    assert equal (sql unwrap-quoted "30") {quoted: false, value: "30"}
}
