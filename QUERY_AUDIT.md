# Query correctness audit

Audit of the property "every structured verb generates a query that is correct,
has the intended semantics, and is faithful to what the user typed, or fails
loudly". Performed 2026-10-09 against the working tree at commit `398ce40` plus
the uncommitted `stats`/typed-aggregates work. The 15 nutest suites were green
before and after; they only cover happy paths, which is why none of the items
below is caught by them.

This file is a work list. Each item has an ID, a status box, the files and
functions involved, the evidence (input, generated query, observed result), the
suggested fix, and the regression test that should land with the fix. Tick the
box and add the commit hash when an item is closed. Items are ordered by
severity within each section; the "Recommended order" section at the end
suggests a sequence that groups fixes sharing a root cause.

## How the findings were verified

Every finding was first obtained through `--dry-run` and then, where marked
"executed", run against a real engine:

- DuckDB: a scratch file with `CREATE TABLE t(id INT, a INT, b INT, status TEXT,
  name TEXT, zip TEXT, amount DECIMAL(10,2), created_at TIMESTAMP, flag BOOLEAN)`
  and a handful of rows. Any `mole-duckdb` connection pointing at a file with
  that table reproduces the SQL items.
- MySQL: the project's own stack, `docker compose -f
  mole-mysql/_devutils/docker-compose.yaml up -d mysql` (mysql:8.4 on 53306,
  root/mole, database `demo`, seeded `users` and `orders` tables).
- MongoDB: `docker compose -f mole-mongodb/_devutils/docker-compose.yaml up -d`
  (mongo:7 on 57017, database `demo`, collections `users`, `orders`, `products`;
  user `alice` carries `big: NumberLong("9007199254740993")` and string
  `address.zip` values).
- VictoriaMetrics and VictoriaLogs: dry-run only; the items state what the
  rendered query would do on the server but no server was consulted.

A useful harness for the SQL items, usable from any driver:

```nu
def probe [label: string, c: closure] {
  let q = (try { do $c true | get query } catch {|e| $"BUILD ERROR: ($e.msg)" })
  let r = (try { do $c false | to nuon } catch {|e| $"EXEC ERROR: ($e.msg)" })
  print $"--- ($label)\n    SQL: ($q)\n    RES: ($r)"
}
probe 'space after comma' {|dry| mole-duckdb select id --from t --where "a=1, b=2" -c du --dry-run=$dry }
```

Driver test suites already have the fixture pattern needed for regression tests
(mktemp dir, `mole/connections.yaml` keyed by driver, `$env.XDG_CONFIG_HOME` and
`$env.XDG_CACHE_HOME`), so each test suggested below is a dry-run assertion that
fits the existing suites.

## A. Silent wrong results

The query executes, returns a wrong or empty set, and nothing tells the user.
`update` and `delete` share the `--where` path with `select`, so A1 through A3
can silently touch the wrong rows or, more often, no rows at all while
reporting success.

### A1. Raw SQL in `--where` is captured as a single predicate token  `[ ]`

- Modules: all SQL drivers (psql, mysql, mariadb, trino, duckdb) via
  `mole-sql/sql.nu` `parse-where` (line 359), `predicate-token` (255),
  `coalesce-preds` (328), `sql-literal` (276).
- Mode: executed on DuckDB and MySQL.

`--where` is dual mode: if every comma-separated item parses as
`col<op>value` it is a token list, otherwise it is raw SQL. The token regex
anchors the column name but lets the value be `.*`, so any raw SQL whose first
operator is written without surrounding spaces parses as one token and the rest
of the expression becomes the string literal.

| input | generated | observed |
|---|---|---|
| `--where "a=1 AND b=2"` | `WHERE a = '1 AND b=2'` | DuckDB: cast error on int column, empty on text column. MySQL: empty |
| `--where "id=7 OR 1=1"` | `WHERE id = '7 OR 1=1'` | MySQL coerces `'7 OR 1=1'` to 7 with warning 1292 and returns row 7 |
| `--where "created_at>now()"` | `WHERE created_at > 'now()'` | error or empty |
| `--where "a=b"` | `WHERE a = 'b'` | column compare becomes string compare, empty |
| `--where "id=ANY(ARRAY[1,2])"` | `WHERE id = 'ANY(ARRAY[1,2])'` | empty |
| `--where "total>0 AND status<>'void'"` | `WHERE total > '0 AND status<>''void'''` | empty |

The existing raw-SQL test passes only because its example has spaces around
the operator (`a = 1`), which fails the column anchor and takes the raw path.
MySQL is the worst case because its string-to-number coercion is a warning,
and the driver does not surface warnings.

Suggested fix: in `parse-where`, after a successful token parse, reject the
token-list interpretation when any value contains whitespace followed by
`AND`, `OR`, `NOT` (case-insensitive) or contains an unbalanced quote or
parenthesis, and fall back to raw. Alternatively require values to be free of
whitespace unless the whole value is quoted. Either way the test should assert
that `a=1 AND b=2` renders as raw SQL.

Regression test: `sql parse-where "a=1 AND b=2"` returns the raw form;
`sql parse-where "id=7 OR 1=1"` returns the raw form; `a=1,b=2` still returns
two tokens.

### A2. Space after a comma folds the next predicate into the previous value  `[ ]`

- Modules: all SQL drivers via `parse-where` (359), `coalesce-preds` (328).
- Mode: executed on DuckDB and MySQL.

`parse-where` does `split row ","` without trimming, unlike the core
`complete csv` helper in `mole/lib/complete.nu` (line 74) which trims and drops
empties. The item ` b=2` has a leading space, fails the `^[a-zA-Z_]` column
anchor, and `coalesce-preds` treats it as the continuation of an `in:` list.

| input | generated | observed |
|---|---|---|
| `--where "a=1, b=2"` | `WHERE a = '1, b=2'` | DuckDB: conversion error. MySQL: empty |

Suggested fix: trim each item in `parse-where` before matching. Keep the
fold-back behaviour only for items that follow an `in:` token.

Regression test: `sql parse-where "a=1, b=2"` yields two tokens equal to
`sql parse-where "a=1,b=2"`.

### A3. Trailing or doubled comma becomes part of the literal  `[ ]`

- Modules: all SQL drivers via `parse-where` (359), `coalesce-preds` (328).
- Mode: executed on DuckDB and MySQL.

| input | generated | observed |
|---|---|---|
| `--where "status=active,"` | `WHERE status = 'active,'` | zero rows on both engines |
| `delete --from t --where "status=active,"` | `DELETE FROM t WHERE status = 'active,'` | deleted nothing, reported success |
| `--where ","` | `WHERE ,` | passes the delete `--all` guard, then syntax error |

Suggested fix: after trimming, drop empty items, and if the result is empty
treat `--where` as absent so the `--all` guard fires. Reject a trailing empty
item explicitly rather than folding it.

Regression test: `sql parse-where "status=active,"` equals
`sql parse-where "status=active"`; `sql parse-where ","` errors or yields no
predicate.

### A4. `build-having` silently drops tokens it cannot parse  `[ ]`

- Modules: psql, mysql, mariadb, trino, duckdb `stats` via `sql build-having`
  (646).
- Mode: executed on DuckDB and MySQL.

| input | generated | observed |
|---|---|---|
| `stats --from orders --by status --count --having "count >= 10"` | no `HAVING` clause at all | unfiltered grouped result |
| `stats --from orders --by status --having "sum_amount>1"` (no `--sum`) | `HAVING sum_amount > 1` | bare alias, engine error |

The function filters tokens through the predicate parser and keeps only the
ones that succeed, so a spaced token vanishes. The PromQL library's
`matchers-tokens` already errors on an unparsable token; `build-having` should
do the same.

Suggested fix: error with the offending token when any HAVING item fails to
parse, and error when an alias in a HAVING token has no matching aggregate
request.

Regression test: `sql build-having ["count >= 10"] …` errors; an alias that
is not among the requested aggregates errors.

### A5. Unknown sort suffix is silently ascending  `[ ]`

- Modules: all SQL drivers via `sql sort-token` (497), `build-order` (520).
- Mode: dry-run (rendering is deterministic).

| input | generated |
|---|---|
| `--sort-by amount:dsc` | `ORDER BY amount` |
| `--sort-by "amount desc"` | `ORDER BY amount desc` (works by accident, passes through as raw) |

The doc comment on `sort-token` calls the fallback intentional, but a top-N
query in the wrong direction is not noticed by the user. Note the grammar
divergence with Mongo, which uses `field desc` (see C3).

Suggested fix: error on a suffix other than `asc`/`desc` (case-insensitive).

Regression test: `sql sort-token "amount:dsc"` errors; `amount:DESC` works.

### A6. Mongo accepts SQL-shaped tokens as truthy-field filters  `[ ]`

- Modules: `mole-mongodb/mongo.nu` `parse-filter-token` (87), `sort-spec`
  (167); `mole-mongodb/mod.nu` `find` (427), `aggregate` (481).
- Mode: executed on MongoDB.

A bare token means `{field: true}`, so any token in another module's grammar
becomes a filter on a non-existent field and returns nothing, and a sort field
with a colon sorts on a non-existent field.

| input | generated | observed |
|---|---|---|
| `find users "age>=30"` | `{"age>=30": true}` | 0 docs (3 expected) |
| `aggregate orders --by status --agg sum:amount --having "sum_amount>=100"` | `$match {"sum_amount>=100": true}` | 0 docs |
| `find users --sort-by age:desc` | `.sort({"age:desc": 1})` | unsorted, no error |
| `find users "age: 30"` | `{"age": " 30"}` | 0 docs |

Suggested fix: in `parse-filter-token`, error when a bare token contains any of
`<>=!~` or whitespace; trim the value after the first colon (or error on a
leading space); in `sort-spec`, error on a field containing `:`.

Regression test: `mongo parse-filter-token "age>=30"` errors;
`mongo sort-spec ["age:desc"]` errors; `mongo parse-filter-token "age:30"`
still yields `{"age": 30}`.

### A7. Mongo scalar coercion loses precision and type  `[ ]`

- Modules: `mole-mongodb/mongo.nu` `coerce-scalar` (49).
- Mode: executed on MongoDB.

| input | generated | observed |
|---|---|---|
| `find users big:9007199254740993` | `{big: 9007199254740993}` (JS double) | mongosh rounds to 9007199254740992, 0 docs, yet the doc reads back exactly through EJSON |
| `find users address.zip:10001` | `{"address.zip": 10001}` | field is a string, 0 docs |
| `find users code:-0`, `code:00`, `flag:TRUE` | quoted strings | inconsistent with `0`, `true` |
| `find users x:1e400` | `{x: 1e400}` | JS Infinity, matches nothing |

Suggested fix: emit `NumberLong("…")` for integers outside ±2^53; emit
`Number(…)`-sized floats only within a sane range; and provide an explicit
escape for strings, for example a quoted value `address.zip:"10001"` is kept as
a string. The second point is the important one because the completer offers
string fields the user cannot currently filter by a numeric-looking value.

Regression test: `mongo coerce-scalar "9007199254740993"` returns
`NumberLong("9007199254740993")`; `mongo coerce-scalar '"10001"'` returns
`"10001"`.

### A8. VictoriaMetrics re-quotes PromQL values and swallows comma lists  `[ ]`

- Modules: `mole-promql/promql.nu` `matcher-token` (233), `matchers-tokens`
  (249); `mole-victoriametrics/mod.nu` `select` (362), `vm-scope` (106).
- Mode: dry-run only.

| input | generated | expected |
|---|---|---|
| `select up 'job="api"'` | `up{job="\"api\""}` | `up{job="api"}` |
| `select up 'job=~"api\|web"'` | `up{job=~"\"api\|web\""}` | `up{job=~"api\|web"}` |
| `select up job=api,env=prod` | `up{job="api,env=prod"}` | two matchers |

Every other module teaches comma lists; PromQL requires one matcher per
positional. Both renderings execute and return an empty vector.

Suggested fix: in `matcher-token`, strip a balanced pair of surrounding double
quotes from the value before escaping, or error on a value that starts with a
quote; in `matchers-tokens` (or the driver's positional split) either split on
unquoted commas or error on a comma in a matcher value.

Regression test: `promql matcher-token 'job="api"'` renders `job="api"`;
`promql matchers-tokens ["job=api,env=prod"]` errors or yields two matchers.

### A9. VictoriaLogs renders an operator token as a bare word filter  `[ ]`

- Modules: `mole-victorialogs/mod.nu` `vl-compose-filter` (248), `select`
  (349); `mole-victorialogs/logsql.nu`.
- Mode: dry-run only.

| input | generated | intended |
|---|---|---|
| `select "status>=500"` | `status>=500` (word filter on the literal text) | `status:>=500` |

Suggested fix: error on a token that contains a comparison operator without
the `field:` prefix, mirroring A6.

Regression test: `vl-compose-filter ["status>=500"]` errors; `status:>=500`
renders unchanged.

### A10. Repeated `--where` flags: last one wins silently  `[ ]`

- Modules: all SQL drivers.
- Mode: dry-run.

`select --where a=1 --where b=2` renders `WHERE b = 2`. This is Nushell flag
semantics, not a parser bug, but worth a note in the flag help so users do not
expect accumulation.

Suggested fix: document it in the `--where` help text; nothing to change in
code unless the flag becomes a list.

### A11. Mongo aggregate alias clash overwrites the group key  `[ ]`

- Modules: `mole-mongodb/mongo.nu` `build-pipeline` (320),
  `parse-agg-token` (275).
- Mode: executed on MongoDB.

| input | generated | observed |
|---|---|---|
| `aggregate orders --by status --agg "count=status"` | `$group {_id: {status: "$status"}, status: {$sum: 1}}` then `$project` | result `[[status]; [1], [1], [4]]`, the key is gone |

Suggested fix: error when an alias equals a `--by` field or another alias.

Regression test: `mongo build-pipeline` with that input errors.

## B. Hard errors

These fail loudly on the engine, so the user sees them, but each is a
reachable feature that cannot work as offered.

### B1. Empty `in:` list renders `IN ()`  `[ ]`

- Modules: all SQL drivers via `sql render-eq` (191).
- Mode: executed on DuckDB and MySQL (syntax error on both).

`--where "role=in:"` renders `role IN ()`. Suggested fix: error in
`render-eq` when the list is empty. Regression test: `sql parse-where
"role=in:"` errors.

### B2. Mongo dotted `--by` keys are rejected by the server  `[ ]`

- Modules: `mole-mongodb/mongo.nu` `build-pipeline` (320), `stat-alias` (231);
  `mole-mongodb/mod.nu` `aggregate` (481) and its `--by` completer.
- Mode: executed on MongoDB.

`aggregate users --by address.city` and `aggregate orders --unwind items --by
items.sku` both render `$group {_id: {"address.city": "$address.city"}}` and
the server answers "FieldPath field names may not contain '.'". The `--by`
completer offers dotted paths, so this is the natural thing to type.

Suggested fix: run the group key through `stat-alias` the way accumulators
already are (`address_city`), and project it back under the dotted name or the
alias. Regression test: `mongo build-pipeline --by ["address.city"]` renders a
`_id` key without a dot.

### B3. Shape-based literal typing guesses the column type  `[ ]`

- Modules: all SQL drivers via `sql sql-literal` (276).
- Mode: executed on DuckDB (errors) and MySQL (silent coercion).

| input | generated | DuckDB on a text column |
|---|---|---|
| `--where "zip=01234"` | `zip = 01234` | `Could not convert string 'AB123' to INT32` |
| `--where "status=true"` | `status = true` | cast error |
| `--where "x=1e5"`, `x=+5`, `x=.5` | quoted strings | error on numeric columns |

MySQL instead coerces with a warning the driver never surfaces, which turns
these into A-class silent misses. The schema cache already knows base-table
column types (`columns-for`, line 724), so the literal could be typed from the
column when the table is known, falling back to shape otherwise. A cheaper
partial fix is to accept the scientific, signed and leading-dot numeric forms
and to never emit a leading-zero integer bare.

Regression test: `sql sql-literal "01234"` returns `'01234'`;
`sql sql-literal "1e5"` returns `1e5`.

### B4. PromQL builder does not validate function arity or step  `[ ]`

- Modules: `mole-promql/promql.nu` `build` (269), `step` (84);
  `mole-victorialogs/logsql.nu` `step` (65).
- Mode: dry-run only.

| input | generated |
|---|---|
| `select up --func rate` (no `--range`) | `rate(up)` |
| `select up --agg topk` | `topk (up)` |
| `promql step 500ms`, `logsql step 500ms` | `0s` |
| `select --limit -1` (SQL drivers) | `LIMIT -1` |

Suggested fix: error when a range-vector function is given without `--range`
and when a parametric aggregator (`topk`, `bottomk`, `quantile`,
`count_values`) is given without its parameter; make `step` error below one
second or render fractional seconds; reject negative `--limit`/`--offset` in
the SQL drivers.

Regression test: `promql build` with `--func rate` and no range errors;
`promql step 500ms` errors.

### B5. Mongo date coercion accepts impossible dates  `[ ]`

- Modules: `mole-mongodb/mongo.nu` `coerce-scalar` (49).
- Mode: executed on MongoDB (`MongoshInvalidInputError`).

`coerce-scalar "2026-13-45"` renders `ISODate("2026-13-45")`. Suggested fix:
parse the value with `into datetime` and error on failure before rendering.

## C. Result typing and semantic inconsistencies

### C1. `min_*` and `max_*` come back as strings  `[ ]`

- Modules: `mole-sql/sql.nu` `apply-agg-types` (698), `result-cols` (627),
  `ansi-aggs` and the dialect `aggs` tables; every SQL driver's `stats`.
- Mode: executed on DuckDB and MySQL.

A `stats` row came back as `min_amount: "10.50"` beside `sum_amount: 30.5`.
`apply-agg-types` only casts aggregates whose spec declares a `type`; `min`
and `max` are untyped, and the comment claiming the driver types them from
the schema is false because `columns-for` only knows base-table columns, not
the aliased result. `sum(int)` is also returned as float `6.0`.

Suggested fix: when the base table is known, look up the source column type
of a `min`/`max`/`sum` request in the schema cache and cast accordingly;
otherwise leave the string, but document it.

Regression test: `apply-agg-types` on a `min` request over an integer column
yields an int.

### C2. Duplicate aggregate requests produce duplicate record keys  `[ ]`

- Modules: `sql agg-requests` (570), `build-aggs` (602).
- Mode: executed on DuckDB.

`--sum amount,amount` renders two `sum_amount` columns and the record ends up
with two keys of the same name, one typed and one not. Suggested fix: dedupe
requests by alias, or error on a clash.

### C3. The four grammars diverge and none rejects a sibling's syntax  `[ ]`

This is the root cause behind A1, A5, A6, A8 and A9 rather than a separate
bug, recorded here so the fixes above are made consistently.

| concern | SQL (mole-sql) | Mongo | PromQL | LogsQL |
|---|---|---|---|---|
| predicate | `col<op>value` | `field:op value` | `label<op>value` | `field:op value` |
| list | comma inside one flag | comma inside one flag | one token per positional | space-joined tokens |
| sort | `col:desc` | `field desc` | n/a | `--sort-by f --desc` |
| unknown input | treated as raw / folded | treated as truthy field | error | treated as word filter |

The minimum consistent rule is: every grammar errors on a token that is
well-formed in another grammar. The PromQL library already does this and is
the model to copy.

## Verified correct

These were probed on the same engines and behaved as intended, so they do not
need attention: comma token lists with tight operators; `in:` lists with
values; `=null` and `<=>null`; `O'Brien` quoting and MySQL backslash doubling;
`name=~^[AB]` regex per dialect (`~`, `REGEXP`, `regexp_like`,
`regexp_matches`); ILIKE on psql; table aliases `--from "t x"`; stats with
HAVING alias expansion when tokens are well formed; Trino `OFFSET n LIMIT m`
ordering; MariaDB update/delete with `ORDER BY` and `LIMIT`; Mongo `$in`,
regex with flags, date buckets and Decimal128 sums; VictoriaMetrics
`sum by (job) (up{job="api"})`; VictoriaLogs stats, sort and limit
pipelines.

## Recommended order

1. A2, A3, B1 together: one change in `parse-where`/`coalesce-preds` (trim,
   drop empties, error on empty `in:`). Smallest diff, covers the `delete`
   hazard.
2. A1: the raw-versus-token decision. Decide the rule first, then write the
   tests, because it changes what the existing raw-SQL test is allowed to
   accept.
3. A4 and A5: make `build-having` and `sort-token` error. Same pattern as
   PromQL's `matchers-tokens`.
4. A6, A9, A11, B2, B5: Mongo and LogsQL token rejection plus dotted group
   keys. These are independent of the SQL work.
5. A7 and B3: literal typing in Mongo and SQL. Both need a decision on whether
   to consult the schema cache; do them together so the policy matches.
6. A8 and B4: PromQL quoting, comma handling and arity. Pair with the pending
   prometheus token refactor in `NEXT_STEPS.md` so both drivers get it once.
7. C1 and C2: aggregate typing. Lowest risk, purely cosmetic for most users.
