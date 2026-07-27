-- Seed data for the mole-psql local dev database.
-- Runs once on first container boot (postgres runs *.sql in this dir in order).
-- Designed to exercise mole-psql: the type map (boolean, integer, numeric,
-- date, timestamp, jsonb), display types, and schema introspection
-- (primary/foreign/unique keys + table & column comments).

CREATE TABLE users (
    id          serial PRIMARY KEY,
    email       varchar(255) NOT NULL UNIQUE,
    full_name   varchar(120) NOT NULL,
    is_active   boolean      NOT NULL DEFAULT true,
    age         integer,
    balance     numeric(10, 2) NOT NULL DEFAULT 0,
    prefs       jsonb,
    created_at  timestamp    NOT NULL DEFAULT now()
);

COMMENT ON TABLE  users            IS 'Application user accounts';
COMMENT ON COLUMN users.is_active  IS 'Whether the account can sign in';
COMMENT ON COLUMN users.balance    IS 'Wallet balance in EUR';
COMMENT ON COLUMN users.prefs      IS 'Free-form user preferences';

CREATE TABLE orders (
    id         serial PRIMARY KEY,
    user_id    integer NOT NULL REFERENCES users (id),
    amount     numeric(10, 2) NOT NULL,
    status     varchar(20) NOT NULL DEFAULT 'pending',
    placed_on  date NOT NULL
);

COMMENT ON TABLE  orders        IS 'Customer orders';
COMMENT ON COLUMN orders.status IS 'pending | paid | shipped | cancelled';

INSERT INTO users (email, full_name, is_active, age, balance, prefs, created_at) VALUES
    ('ada@example.com',   'Ada Lovelace',    true,  36, 1200.50, '{"theme":"dark","newsletter":true}',  '2024-01-15 09:30:00'),
    ('alan@example.com',  'Alan Turing',     true,  41,  340.00, '{"theme":"light","newsletter":false}', '2024-02-01 14:05:00'),
    ('grace@example.com', 'Grace Hopper',    false, 85,    0.00, '{"theme":"dark"}',                     '2024-03-10 08:00:00'),
    ('linus@example.com', 'Linus Torvalds',  true,  54,   75.25, NULL,                                   '2024-04-22 18:45:00');

INSERT INTO orders (user_id, amount, status, placed_on) VALUES
    (1, 199.99, 'paid',      '2024-05-01'),
    (1,  49.00, 'shipped',   '2024-05-03'),
    (2,  12.50, 'pending',   '2024-05-04'),
    (4, 500.00, 'cancelled', '2024-05-06');
