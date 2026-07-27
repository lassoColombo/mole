use std/assert
use std/testing *
use ../mermaid.nu

# ---- empty / trivial ----------------------------------------------------------

@test
def "empty schema renders a placeholder" [] {
  let out = ({tables: [], columns: [], constraints: []} | mermaid er-diagram)
  assert equal $out "erDiagram\n    %% no tables in schema"
}

@test
def "a table with no columns renders an empty entity body" [] {
  let data = {
    tables: [{schema: public, name: empties, type: "BASE TABLE", comment: null, row_estimate: 0}]
    columns: []
    constraints: []
  }
  assert equal ($data | mermaid er-diagram) "erDiagram\n    empties {}"
}

# ---- columns, keys, types -----------------------------------------------------

@test
def "one table with a primary-key column" [] {
  let data = {
    tables: [{schema: public, name: users, type: "BASE TABLE", comment: null, row_estimate: 1}]
    columns: [{schema: public, table: users, name: id, position: 1, display_type: int4, nullable: false, comment: null}]
    constraints: [{schema: public, table: users, name: users_pk, type: "PRIMARY KEY", columns: [id], ref_schema: null, ref_table: null, ref_columns: null}]
  }
  assert equal ($data | mermaid er-diagram) "erDiagram\n    users {\n        int4 id PK\n    }"
}

@test
def "columns are ordered by position" [] {
  let data = {
    tables: [{schema: public, name: t, type: "BASE TABLE", comment: null, row_estimate: 0}]
    columns: [
      {schema: public, table: t, name: b, position: 2, display_type: text, nullable: true, comment: null}
      {schema: public, table: t, name: a, position: 1, display_type: int4, nullable: true, comment: null}
    ]
    constraints: []
  }
  let out = ($data | mermaid er-diagram)
  assert ((($out | str index-of "int4 a") < ($out | str index-of "text b")))
}

@test
def "a column that is PK, FK and UK shows all three markers" [] {
  let data = {
    tables: [{schema: public, name: t, type: "BASE TABLE", comment: null, row_estimate: 0}]
    columns: [{schema: public, table: t, name: c, position: 1, display_type: int4, nullable: false, comment: null}]
    constraints: [
      {schema: public, table: t, name: t_pk, type: "PRIMARY KEY", columns: [c], ref_schema: null, ref_table: null, ref_columns: null}
      {schema: public, table: t, name: t_uk, type: "UNIQUE", columns: [c], ref_schema: null, ref_table: null, ref_columns: null}
      {schema: public, table: t, name: t_fk, type: "FOREIGN KEY", columns: [c], ref_schema: public, ref_table: other, ref_columns: [id]}
    ]
  }
  assert str contains ($data | mermaid er-diagram) "int4 c PK,FK,UK"
}

@test
def "display_type falls back to data_type then unknown" [] {
  let data = {
    tables: [{schema: public, name: t, type: "BASE TABLE", comment: null, row_estimate: 0}]
    columns: [
      {schema: public, table: t, name: a, position: 1, data_type: bigint, nullable: true, comment: null}
      {schema: public, table: t, name: b, position: 2, nullable: true, comment: null}
    ]
    constraints: []
  }
  let out = ($data | mermaid er-diagram)
  assert str contains $out "bigint a"
  assert str contains $out "unknown b"
}

# ---- identifiers & comments (Mermaid whitespace-safety) -----------------------

@test
def "table and column names are squeezed to safe identifiers" [] {
  let data = {
    tables: [{schema: public, name: "my table!", type: "BASE TABLE", comment: null, row_estimate: 0}]
    columns: [{schema: public, table: "my table!", name: "weird name", position: 1, display_type: text, nullable: true, comment: null}]
    constraints: []
  }
  let out = ($data | mermaid er-diagram)
  assert str contains $out "    my_table {"
  assert str contains $out "text weird_name"
}

@test
def "comments are collapsed, quote-escaped and quoted" [] {
  let data = {
    tables: [{schema: public, name: t, type: "BASE TABLE", comment: null, row_estimate: 0}]
    columns: [{schema: public, table: t, name: c, position: 1, display_type: text, nullable: true, comment: "line one\n  has \"quotes\""}]
    constraints: []
  }
  assert str contains ($data | mermaid er-diagram) "text c \"line one has 'quotes'\""
}

# ---- multi-schema qualification -----------------------------------------------

@test
def "entity ids are bare for a single schema" [] {
  let data = {
    tables: [{schema: public, name: users, type: "BASE TABLE", comment: null, row_estimate: 0}]
    columns: []
    constraints: []
  }
  assert str contains ($data | mermaid er-diagram) "    users {}"
}

@test
def "entity ids are schema-qualified across multiple schemas" [] {
  let data = {
    tables: [
      {schema: public, name: users, type: "BASE TABLE", comment: null, row_estimate: 0}
      {schema: audit, name: users, type: "BASE TABLE", comment: null, row_estimate: 0}
    ]
    columns: []
    constraints: []
  }
  let out = ($data | mermaid er-diagram)
  assert str contains $out "    public_users {}"
  assert str contains $out "    audit_users {}"
}

# ---- foreign-key relationships ------------------------------------------------

def fk-sample [nullable_fk: bool] {
  {
    tables: [
      {schema: public, name: users, type: "BASE TABLE", comment: null, row_estimate: 0}
      {schema: public, name: orders, type: "BASE TABLE", comment: null, row_estimate: 0}
    ]
    columns: [
      {schema: public, table: users, name: id, position: 1, display_type: int4, nullable: false, comment: null}
      {schema: public, table: orders, name: id, position: 1, display_type: int4, nullable: false, comment: null}
      {schema: public, table: orders, name: user_id, position: 2, display_type: int4, nullable: $nullable_fk, comment: null}
    ]
    constraints: [
      {schema: public, table: users, name: users_pk, type: "PRIMARY KEY", columns: [id], ref_schema: null, ref_table: null, ref_columns: null}
      {schema: public, table: orders, name: orders_pk, type: "PRIMARY KEY", columns: [id], ref_schema: null, ref_table: null, ref_columns: null}
      {schema: public, table: orders, name: orders_user_fk, type: "FOREIGN KEY", columns: [user_id], ref_schema: public, ref_table: users, ref_columns: [id]}
    ]
  }
}

@test
def "a non-nullable FK is a mandatory relationship" [] {
  assert str contains (fk-sample false | mermaid er-diagram) "    users ||--o{ orders : \"orders_user_fk\""
}

@test
def "a nullable FK is an optional relationship" [] {
  assert str contains (fk-sample true | mermaid er-diagram) "    users |o--o{ orders : \"orders_user_fk\""
}

@test
def "the FK column carries an FK marker" [] {
  assert str contains (fk-sample false | mermaid er-diagram) "int4 user_id FK"
}

@test
def "a FK to an uncached table auto-creates the parent entity" [] {
  # Only `orders` is cached; its FK references `users`, which is not a cached table.
  let data = {
    tables: [{schema: public, name: orders, type: "BASE TABLE", comment: null, row_estimate: 0}]
    columns: [{schema: public, table: orders, name: user_id, position: 1, display_type: int4, nullable: false, comment: null}]
    constraints: [{schema: public, table: orders, name: orders_user_fk, type: "FOREIGN KEY", columns: [user_id], ref_schema: public, ref_table: users, ref_columns: [id]}]
  }
  let out = ($data | mermaid er-diagram)
  assert str contains $out "    users ||--o{ orders : \"orders_user_fk\""
  # No explicit entity block is emitted for the uncached parent — Mermaid makes it.
  assert (not ($out | str contains "    users {"))
}
