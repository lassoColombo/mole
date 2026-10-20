use std/assert
use std/testing *
use mole-mongodb

# Point mole at a throwaway config holding a mongodb + a psql connection (the latter so
# the cross-driver isolation test has something to reject) and at a throwaway cache
# dir. --env so the XDG overrides land in the calling test's environment. Every verb
# is exercised through `--dry-run`, so no mongosh and no server are needed.
def --env fixture [] {
  let d = (mktemp -d)
  mkdir ([$d mole] | path join)
  {connections: {
    mongodb: [{name: mongodb-local-dev, host: "127.0.0.1", port: 27017, user: app, password: secret, database: demo}]
    psql:    [{name: postgres-local-dev, host: "127.0.0.1", port: 5432, user: app, password: secret, database: app}]
  }}
  | to yaml
  | save --force ([$d mole connections.yaml] | path join)
  $env.XDG_CONFIG_HOME = $d
  $env.XDG_CACHE_HOME = ([$d cache] | path join)
}

# ---- find ---------------------------------------------------------------------

@test
def "dry-run find composes filter projection sort and paging" [] {
  fixture
  assert equal (mole-mongodb find role:admin age:>=30 -C users --select name,email --sort-by "age desc" --limit 5 --skip 10 -c mongodb-local-dev --dry-run | get query) 'db.getCollection("users").find({$and: [{"role": "admin"}, {"age": {$gte: 30}}]}, {"name": 1, "email": 1, "_id": 0}).sort({"age": -1}).skip(10).limit(5).toArray()'
  assert equal (mole-mongodb find -C users -c mongodb-local-dev --dry-run | get query) 'db.getCollection("users").find({}).toArray()'
  # find keeps dotted paths as-is (no flattening outside aggregate)
  assert equal (mole-mongodb find address.city:x -C users --sort-by address.city:desc -c mongodb-local-dev --dry-run | get query) 'db.getCollection("users").find({"address.city": "x"}).sort({"address.city": -1}).toArray()'
}

@test
def "find guards" [] {
  fixture
  assert error { mole-mongodb find -c mongodb-local-dev --dry-run }                                   # --collection required
  assert error { mole-mongodb find -C users --select a --exclude b -c mongodb-local-dev --dry-run }   # can't mix include/exclude
  assert error { mole-mongodb find "role:" -C users -c mongodb-local-dev --dry-run }                  # degenerate token
  assert error { mole-mongodb find "age>=30" -C users -c mongodb-local-dev --dry-run }                # SQL spelling
}

# ---- aggregate ----------------------------------------------------------------

@test
def "dry-run aggregate composes the pipeline" [] {
  fixture
  assert equal (mole-mongodb aggregate active -C orders --by customer --agg count,sum:amount --sort-by "sum_amount desc" --limit 10 -c mongodb-local-dev --dry-run | get query) 'db.getCollection("orders").aggregate([{$match: {"active": true}}, {$group: {_id: {"customer": "$customer"}, "count": {$sum: 1}, "sum_amount": {$sum: "$amount"}}}, {$project: {"_id": 0, "customer": "$_id.customer", "count": 1, "sum_amount": 1}}, {$sort: {"sum_amount": -1}}, {$limit: 10}]).toArray()'
}

@test
def "dry-run aggregate --having is one token whose value may hold commas" [] {
  fixture
  assert equal (mole-mongodb aggregate -C orders --by customer --agg count --having "customer:in:a,b" -c mongodb-local-dev --dry-run | get query) 'db.getCollection("orders").aggregate([{$group: {_id: {"customer": "$customer"}, "count": {$sum: 1}}}, {$project: {"_id": 0, "customer": "$_id.customer", "count": 1}}, {$match: {"customer": {$in: ["a", "b"]}}}]).toArray()'
  assert equal (mole-mongodb aggregate -C requests --by route --agg count --having "count:>=100" -c mongodb-local-dev --dry-run | get query | str contains '{$match: {"count": {$gte: 100}}}') true
  assert error { mole-mongodb aggregate -C orders --by customer --agg count --having "count>=100" -c mongodb-local-dev --dry-run }   # SQL spelling
}

@test
def "dry-run aggregate accepts the dotted spelling of a flattened key in --sort-by and --having" [] {
  fixture
  let q = (mole-mongodb aggregate -C users --by address.city --agg count --sort-by "address.city desc" --having "address.city:x" -c mongodb-local-dev --dry-run | get query)
  assert equal $q 'db.getCollection("users").aggregate([{$group: {_id: {"address_city": "$address.city"}, "count": {$sum: 1}}}, {$project: {"_id": 0, "address_city": "$_id.address_city", "count": 1}}, {$match: {"address_city": "x"}}, {$sort: {"address_city": -1}}]).toArray()'
  # the flat spelling works too
  assert equal (mole-mongodb aggregate -C users --by address.city --agg count --sort-by address_city -c mongodb-local-dev --dry-run | get query | str contains '{$sort: {"address_city": 1}}') true
}

@test
def "aggregate guards" [] {
  fixture
  assert error { mole-mongodb aggregate -C orders -c mongodb-local-dev --dry-run }                                   # needs --by/--agg/--date-bucket
  assert error { mole-mongodb aggregate -C orders --by status --agg count=status -c mongodb-local-dev --dry-run }    # alias clashes with a key
  assert error { mole-mongodb aggregate -C orders --by status --agg count=_id -c mongodb-local-dev --dry-run }
  assert error { mole-mongodb aggregate -C orders --agg "maxN:amount:abc" -c mongodb-local-dev --dry-run }          # param must be numeric
  assert error { mole-mongodb aggregate -C orders --agg "count:amount" -c mongodb-local-dev --dry-run }
}

# ---- count / distinct ---------------------------------------------------------

@test
def "dry-run count and distinct" [] {
  fixture
  assert equal (mole-mongodb count active role:admin -C users -c mongodb-local-dev --dry-run | get query) 'db.getCollection("users").countDocuments({$and: [{"active": true}, {"role": "admin"}]})'
  assert equal (mole-mongodb distinct region status:paid -C orders --limit 10 -c mongodb-local-dev --dry-run | get query) 'db.getCollection("orders").aggregate([{$match: {"status": "paid"}}, {$group: {_id: "$region", count: {$sum: 1}}}, {$sort: {count: -1}}, {$limit: 10}, {$project: {_id: 0, value: "$_id", count: 1}}]).toArray()'
}

# ---- connection handling ------------------------------------------------------

@test
def "dry-run redacts the password and rejects other drivers" [] {
  fixture
  let r = (mole-mongodb count -C users -c mongodb-local-dev --dry-run)
  assert equal ($r.connection.driver) "mongodb"
  assert equal ($r.connection.name) "mongodb-local-dev"
  assert equal ("password" in ($r.connection | columns)) false
  assert error { mole-mongodb count -C users -c postgres-local-dev --dry-run }
  assert error { mole-mongodb set-connection postgres-local-dev }
}
