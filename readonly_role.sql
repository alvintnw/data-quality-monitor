-- Optional but strongly recommended: a read-only role for the "Postgres (read-only)" credential,
-- used ONLY by the "Run Check" node. Rule definitions come from the dq_rules table, so a
-- read-only role with a statement timeout keeps a bad rule from changing data or running forever.
-- Run as a superuser on the database that holds the data you want to monitor.
CREATE ROLE dq_reader LOGIN PASSWORD 'CHANGE_ME';
GRANT CONNECT ON DATABASE your_database TO dq_reader;
GRANT USAGE ON SCHEMA public TO dq_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO dq_reader;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO dq_reader;
ALTER ROLE dq_reader SET statement_timeout = '30s';
ALTER ROLE dq_reader SET default_transaction_read_only = on;
-- Do not grant access to the dq_* state tables or to tables with secrets.
