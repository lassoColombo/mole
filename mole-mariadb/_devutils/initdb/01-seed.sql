-- Seed data for the mole-mariadb local dev database.
-- Runs once on first container boot (mariadb runs *.sql in this dir in order).
-- The mole-mysql seed verbatim — MariaDB accepts the same DDL — so mole-mariadb
-- can be exercised side by side with mole-mysql / mole-psql. Hits mole-mariadb's
-- type map: tinyint(1)->bool, int, decimal, date/datetime/timestamp, plus schema
-- introspection (primary/foreign/unique keys + table & column comments).
--
-- NOTE: the `prefs` column is declared `json`, but on MariaDB `json` is an ALIAS
-- for LONGTEXT, so information_schema reports `longtext` and mole-mariadb returns
-- it as a STRING (unlike mole-mysql, which parses native json). That divergence is
-- intentional and is what this dev stack demonstrates.

CREATE TABLE users (
    id          int AUTO_INCREMENT PRIMARY KEY,
    email       varchar(255) NOT NULL UNIQUE,
    full_name   varchar(120) NOT NULL,
    is_active   tinyint(1)   NOT NULL DEFAULT 1 COMMENT 'Whether the account can sign in',
    age         int,
    balance     decimal(10, 2) NOT NULL DEFAULT 0 COMMENT 'Wallet balance in EUR',
    prefs       json COMMENT 'Free-form user preferences (LONGTEXT-backed on MariaDB)',
    created_at  timestamp    NOT NULL DEFAULT CURRENT_TIMESTAMP
) COMMENT = 'Application user accounts';

CREATE TABLE orders (
    id         int AUTO_INCREMENT PRIMARY KEY,
    user_id    int NOT NULL,
    amount     decimal(10, 2) NOT NULL,
    status     varchar(20) NOT NULL DEFAULT 'pending' COMMENT 'pending | paid | shipped | cancelled',
    placed_on  date NOT NULL,
    CONSTRAINT fk_orders_user FOREIGN KEY (user_id) REFERENCES users (id)
) COMMENT = 'Customer orders';

INSERT INTO users (email, full_name, is_active, age, balance, prefs, created_at) VALUES
    ('ada@example.com',   'Ada Lovelace',   1, 36, 1200.50, '{"theme":"dark","newsletter":true}',  '2024-01-15 09:30:00'),
    ('alan@example.com',  'Alan Turing',    1, 41,  340.00, '{"theme":"light","newsletter":false}', '2024-02-01 14:05:00'),
    ('grace@example.com', 'Grace Hopper',   0, 85,    0.00, '{"theme":"dark"}',                     '2024-03-10 08:00:00'),
    ('linus@example.com', 'Linus Torvalds', 1, 54,   75.25, NULL,                                   '2024-04-22 18:45:00');

INSERT INTO orders (user_id, amount, status, placed_on) VALUES
    (1, 199.99, 'paid',      '2024-05-01'),
    (1,  49.00, 'shipped',   '2024-05-03'),
    (2,  12.50, 'pending',   '2024-05-04'),
    (4, 500.00, 'cancelled', '2024-05-06');
