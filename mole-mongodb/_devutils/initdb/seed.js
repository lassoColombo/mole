// Seed the `demo` database for mole-mongodb dev / e2e. Runs once on first boot via
// the mongo image's /docker-entrypoint-initdb.d hook (`db` = MONGO_INITDB_DATABASE).
//
// Deliberately exercises: every decoded BSON type (ObjectId, ISODate, NumberInt,
// NumberLong > 2^53, Decimal128, nested doc, array, array-of-subdocs); a
// mixed-type field (`legacyId`: int vs string) and a partial field (present in
// some docs only) for schema inference; and a VIEW (collection type).

db.users.insertMany([
  { name: "alice", age: NumberInt(30), active: true,  role: "admin",
    created: ISODate("2026-01-02T03:04:05.678Z"), score: NumberDecimal("9.95"),
    big: NumberLong("9007199254740993"),                       // > 2^53, precision probe
    address: { city: "NYC", zip: "10001" }, tags: ["red", "blue"], legacyId: NumberInt(1) },
  { name: "bob",   age: NumberInt(25), active: false, role: "user",
    created: ISODate("2026-01-03T00:00:00Z"), score: NumberDecimal("1.50"),
    address: { city: "LA",  zip: "90001" }, tags: ["blue"], legacyId: "L-2" }, // mixed-type
  { name: "carol", age: NumberInt(41), active: true,  role: "user",
    created: ISODate("2026-02-01T00:00:00Z"), score: NumberDecimal("42.00"),
    address: { city: "NYC", zip: "10002" }, tags: [] },        // no legacyId (partial field)
  { name: "dave",  age: NumberInt(37), active: true,  role: "editor",
    created: ISODate("2026-02-10T12:30:00Z"), score: NumberDecimal("0.00"),
    address: { city: "SF",  zip: "94102" }, tags: ["green", "blue"], legacyId: NumberInt(4) },
]);

db.orders.insertMany([
  { customer: "alice", amount: NumberDecimal("120.00"), active: true,  status: "paid",
    created: ISODate("2026-01-05T10:00:00Z"), region: "east",
    items: [ { sku: "x1", qty: NumberInt(2), price: 60.0 } ] },
  { customer: "alice", amount: NumberDecimal("80.50"),  active: true,  status: "paid",
    created: ISODate("2026-01-06T11:00:00Z"), region: "east",
    items: [ { sku: "x2", qty: NumberInt(1), price: 80.5 } ] },
  { customer: "bob",   amount: NumberDecimal("15.00"),  active: false, status: "cancelled",
    created: ISODate("2026-01-07T09:00:00Z"), region: "west",
    items: [ { sku: "x1", qty: NumberInt(1), price: 15.0 } ] },
  { customer: "bob",   amount: NumberDecimal("200.00"), active: true,  status: "paid",
    created: ISODate("2026-01-08T14:00:00Z"), region: "west",
    items: [ { sku: "x3", qty: NumberInt(4), price: 50.0 } ] },
  { customer: "carol", amount: NumberDecimal("42.00"),  active: true,  status: "pending",
    created: ISODate("2026-02-02T08:00:00Z"), region: "east",
    items: [ { sku: "x2", qty: NumberInt(1), price: 42.0 } ] },
  { customer: "carol", amount: NumberDecimal("9.99"),   active: true,  status: "paid",
    created: ISODate("2026-02-03T08:00:00Z"), region: "east",
    items: [ { sku: "x4", qty: NumberInt(3), price: 3.33 } ] },
]);

db.products.insertMany([
  { sku: "x1", name: "Widget",  price: NumberDecimal("60.00"), in_stock: true,  attrs: { color: "red",   size: "M" } },
  { sku: "x2", name: "Gadget",  price: NumberDecimal("80.50"), in_stock: true,  attrs: { color: "blue",  size: "L" } },
  { sku: "x3", name: "Gizmo",   price: NumberDecimal("50.00"), in_stock: false, attrs: { color: "green", size: "S" } },
  { sku: "x4", name: "Doohickey", price: NumberDecimal("3.33"), in_stock: true, attrs: { color: "blue",  size: "M" } },
]);

// A secondary index (exercises the `indexes` verb) and a VIEW (collection type).
db.orders.createIndex({ customer: 1, created: -1 });
db.createView("paid_orders", "orders", [{ $match: { status: "paid" } }]);

print("seeded demo: users=" + db.users.countDocuments() + " orders=" + db.orders.countDocuments() + " products=" + db.products.countDocuments());
