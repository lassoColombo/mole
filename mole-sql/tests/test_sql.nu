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
    assert equal (sql sql-literal "true") "true"
    assert equal (sql sql-literal "False") "false"
    assert equal (sql sql-literal "O'Brien") "'O''Brien'"
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
    # build-where threads the SAME injected ops end-to-end (dual-mode, structured path)
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
def "parse-where discriminates token-lists from raw SQL" [] {
    assert equal (sql parse-where "status=active,age>=30") [{col: status, op: "=", value: active} {col: age, op: ">=", value: "30"}]
    assert equal (sql parse-where "role=in:admin,ops") [{col: role, op: "=", value: "in:admin,ops"}]   # in: list folds back over the comma
    assert equal (sql parse-where "status=active,role=in:a,b,age>=1") [{col: status, op: "=", value: active} {col: role, op: "=", value: "in:a,b"} {col: age, op: ">=", value: "1"}]
    assert equal (sql parse-where "status = 'active' AND age > 5") null    # spaced operators ⇒ not a token-list ⇒ raw
    assert equal (sql parse-where "(a OR b) AND c") null                    # leading non-token ⇒ raw
    assert equal (sql parse-where "") []                                    # empty ⇒ no predicates (still structured)
}

@test
def "render-where AND-joins predicate records" [] {
    assert equal (sql render-where [{col: status, op: "=", value: active} {col: age, op: ">=", value: "30"}]) "status = 'active' AND age >= 30"
    assert equal (sql render-where []) null
    let q = "'"
    assert equal (sql render-where [{col: path, op: "=", value: 'a\b'}] --dialect {backslash_escapes: true}) ("path = " + $q + 'a\\b' + $q)   # dialect escaping threads through
}

@test
def "build-where is dual-mode: structured tokens or raw SQL verbatim" [] {
    # structured: parses ⇒ rendered per-dialect (the token grammar)
    assert equal (sql build-where "status=active,age>=30") "status = 'active' AND age >= 30"
    assert equal (sql build-where "role=in:admin,ops") "role IN ('admin', 'ops')"
    assert equal (sql build-where "deleted=null") "deleted IS NULL"
    assert equal (sql build-where "name~%John Smith%") "name LIKE '%John Smith%'"   # a space in the VALUE is fine
    # raw fallback: doesn't parse ⇒ verbatim (idiomatic spaced SQL, functions, parens)
    assert equal (sql build-where "created_at > now() - interval '1 day'") "created_at > now() - interval '1 day'"
    assert equal (sql build-where "id = 42") "id = 42"
    assert equal (sql build-where "(a OR b) AND c") "(a OR b) AND c"
    assert equal (sql build-where "") null
    # dual-mode threads INJECTED dialect ops into the structured path (regex → function form)
    let ops = (sql ansi-ops | append {token: "=~", desc: "regex", render: {|c, v, lit| sql render-func "regexp_like" $c $v $lit }})
    assert equal (sql build-where "name=~^a" --ops $ops) "regexp_like(name, '^a')"
    assert equal (sql build-where "name ~ '^a'" --ops $ops) "name ~ '^a'"           # spaced ⇒ raw even with custom ops
}

@test
def "sort-token parses col and optional direction" [] {
    assert equal (sql sort-token "created_at") {col: "created_at", dir: ""}
    assert equal (sql sort-token "amount:desc") {col: "amount", dir: "DESC"}
    assert equal (sql sort-token "name:asc") {col: "name", dir: "ASC"}
    assert equal (sql sort-token "") null
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
def "where-clause wraps the dual-mode body or drops it" [] {
    assert equal (sql where-clause "status=active,age>=30") "WHERE status = 'active' AND age >= 30"
    assert equal (sql where-clause "a > 1 OR b") "WHERE a > 1 OR b"
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
