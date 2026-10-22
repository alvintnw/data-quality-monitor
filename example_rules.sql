-- Example rules for a fictional "orders" table. Adjust table and column names, then run.
-- orders(id, customer_id, status, total, created_at, email)
-- Safe to run more than once (rules are matched by name).
INSERT INTO dq_rules (name, kind, table_name, column_name, key_columns, where_clause, window_minutes, min_value, max_value, anomaly_k, severity, interval_minutes, min_failures, reminder_minutes) VALUES
 ('orders: fresh within 30 min',             'freshness_minutes', 'orders', 'created_at', NULL,                    NULL,                 NULL, NULL, 30,   NULL, 'critical', 5,   2, 60),
 ('orders: table not empty',                 'row_count',         'orders', NULL,         NULL,                    NULL,                 NULL, 1,    NULL, NULL, 'critical', 60,  1, 240),
 ('orders: email null rate under 2%',        'null_pct',          'orders', 'email',      NULL,                    NULL,                 NULL, NULL, 2,    NULL, 'warning',  60,  1, 0),
 ('orders: no duplicate customer+timestamp', 'duplicate_count',   'orders', NULL,         'customer_id,created_at', 'status <> ''test''', NULL, NULL, 0,    NULL, 'warning',  120, 1, 0),
 ('orders: hourly volume looks normal',      'window_count',      'orders', 'created_at', NULL,                    NULL,                 60,   NULL, NULL, 4,    'warning',  60,  2, 0)
ON CONFLICT (name) DO NOTHING;

-- Custom SQL: must be one SELECT (or WITH ... SELECT) returning a single numeric column named "value".
INSERT INTO dq_rules (name, kind, custom_sql, max_value, severity, interval_minutes, min_failures, reminder_minutes)
VALUES ('orders: no negative totals', 'custom_sql', 'SELECT count(*) AS value FROM orders WHERE total < 0', 0, 'critical', 30, 1, 120)
ON CONFLICT (name) DO NOTHING;
