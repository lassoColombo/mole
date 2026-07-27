# mole-trino dev fixtures — no seeding needed

Unlike the mole-psql / mole-mysql dev stacks, this one seeds **nothing**.

The `trinodb/trino:latest` image ships the built-in [`tpch`
connector](https://trino.io/docs/current/connector/tpch.html) enabled by
default. It synthesizes the TPC-H benchmark dataset on the fly, exposing
ready-made schemas at several scale factors:

- `tpch.tiny`   — smallest, used by the `trino-local-dev` connection
- `tpch.sf1`, `tpch.sf100`, … — larger scale factors

Each schema has real tables with a spread of column types that exercise the
plugin's type map and schema introspection:

| table      | notable columns / types                                        |
|------------|----------------------------------------------------------------|
| `customer` | `custkey` bigint, `name` varchar, `acctbal` double, `nationkey` bigint |
| `orders`   | `orderkey` bigint, `orderdate` date, `totalprice` double, `orderstatus` varchar |
| `lineitem` | `quantity`/`extendedprice`/`discount`/`tax` double, `shipdate`/`commitdate`/`receiptdate` date |
| `nation`, `region`, `part`, `supplier`, `partsupp` | more of the same |

So `mole-trino schema -c trino-local-dev` lists the `tpch.tiny` tables and
`mole-trino select custkey name acctbal --from customer -c trino-local-dev
--limit 5` exercises bigint/varchar/double typing with no fixtures to load.

Note: Trino exposes **no** primary/foreign-key metadata, so the schema view's
`pk` column is always empty and the detail view's `constraints` list is always
empty — this is expected, not a bug.

If you ever need a catalog with different types (e.g. `decimal`, `timestamp`),
mount a `*.properties` catalog file into `/etc/trino/catalog/` in the compose
file. tpch alone covers the read/typing tests, so nothing is mounted here.
