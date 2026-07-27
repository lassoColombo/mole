-- Seed data for the mole-duckdb local dev database.
-- Builds /data/demo.duckdb (see docker-compose.yaml) — or run it directly with
-- the duckdb CLI (see the header of docker-compose.yaml for the one-liner).
-- Designed to exercise mole-duckdb: the type map (BOOLEAN, INTEGER/BIGINT/…,
-- DOUBLE, DECIMAL, DATE, TIMESTAMP, TIMESTAMPTZ, JSON, VARCHAR), display types,
-- and schema introspection (primary/foreign/unique keys + table & column
-- comments, which DuckDB supports via COMMENT ON ...).

CREATE TABLE users (
    id          INTEGER      PRIMARY KEY,
    email       VARCHAR(255) NOT NULL UNIQUE,
    full_name   VARCHAR(120) NOT NULL,
    is_active   BOOLEAN      NOT NULL DEFAULT true,
    age         INTEGER,
    balance     DECIMAL(10, 2) NOT NULL DEFAULT 0,
    score       DOUBLE,
    prefs       JSON,
    created_at  TIMESTAMP    NOT NULL DEFAULT now(),
    seen_at     TIMESTAMPTZ,
    born        DATE
);

COMMENT ON TABLE  users            IS 'Application user accounts';
COMMENT ON COLUMN users.is_active  IS 'Whether the account can sign in';
COMMENT ON COLUMN users.balance    IS 'Wallet balance in EUR';
COMMENT ON COLUMN users.prefs      IS 'Free-form user preferences';

CREATE TABLE orders (
    id         INTEGER PRIMARY KEY,
    user_id    INTEGER NOT NULL REFERENCES users (id),
    amount     DECIMAL(10, 2) NOT NULL,
    status     VARCHAR(20) NOT NULL DEFAULT 'pending',
    placed_on  DATE NOT NULL
);

COMMENT ON TABLE  orders        IS 'Customer orders';
COMMENT ON COLUMN orders.status IS 'pending | paid | shipped | cancelled';

INSERT INTO users (id, email, full_name, is_active, age, balance, score, prefs, created_at, seen_at, born) VALUES
    (1, 'ada@example.com',   'Ada Lovelace',   true,  36, 1200.50, 9.75, '{"theme":"dark","newsletter":true}',  '2024-01-15 09:30:00', '2024-06-01 08:00:00+00', '1815-12-10'),
    (2, 'alan@example.com',  'Alan Turing',    true,  41,  340.00, 8.20, '{"theme":"light","newsletter":false}', '2024-02-01 14:05:00', '2024-06-02 12:30:00+00', '1912-06-23'),
    (3, 'grace@example.com', 'Grace Hopper',   false, 85,    0.00, 7.10, '{"theme":"dark"}',                     '2024-03-10 08:00:00', NULL,                     '1906-12-09'),
    (4, 'linus@example.com', 'Linus Torvalds', true,  54,   75.25, NULL, NULL,                                   '2024-04-22 18:45:00', '2024-06-04 22:15:00+00', '1969-12-28');

INSERT INTO orders (id, user_id, amount, status, placed_on) VALUES
    (1, 1, 199.99, 'paid',      '2024-05-01'),
    (2, 1,  49.00, 'shipped',   '2024-05-03'),
    (3, 2,  12.50, 'pending',   '2024-05-04'),
    (4, 4, 500.00, 'cancelled', '2024-05-06');
