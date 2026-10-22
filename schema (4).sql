-- Data Quality Monitor: state tables. Safe to run more than once.
-- Run this on the database used by the "Postgres (state)" credential.

CREATE TABLE IF NOT EXISTS dq_rules (
  id               SERIAL PRIMARY KEY,
  name             TEXT NOT NULL UNIQUE CHECK (length(name) BETWEEN 1 AND 80),
  kind             TEXT NOT NULL CHECK (kind IN ('row_count','freshness_minutes','null_pct','duplicate_count','window_count','custom_sql')),
  table_name       TEXT,            -- "orders" or "public.orders"; identifiers only
  column_name      TEXT,            -- timestamp column (freshness, window_count) or checked column (null_pct)
  key_columns      TEXT,            -- comma separated, for duplicate_count: "customer_id,order_date"
  where_clause     TEXT,            -- optional filter, e.g. "status <> 'test'"
  window_minutes   INT CHECK (window_minutes BETWEEN 1 AND 525600),
  custom_sql       TEXT,            -- SELECT returning one numeric column named value
  min_value        DOUBLE PRECISION,
  max_value        DOUBLE PRECISION,
  anomaly_k        DOUBLE PRECISION CHECK (anomaly_k > 0),   -- robust z-score limit against recent history
  severity         TEXT NOT NULL DEFAULT 'warning' CHECK (severity IN ('warning','critical')),
  interval_minutes INT NOT NULL DEFAULT 60 CHECK (interval_minutes BETWEEN 1 AND 10080),
  min_failures     INT NOT NULL DEFAULT 1 CHECK (min_failures BETWEEN 1 AND 100),   -- consecutive failures before an incident opens
  reminder_minutes INT NOT NULL DEFAULT 0 CHECK (reminder_minutes >= 0),            -- 0 = never remind
  enabled          BOOLEAN NOT NULL DEFAULT TRUE,
  snooze_until     TIMESTAMPTZ,
  next_run_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_status      TEXT CHECK (last_status IN ('ok','fail','error')),
  last_value       DOUBLE PRECISION,
  last_checked_at  TIMESTAMPTZ,
  fail_streak      INT NOT NULL DEFAULT 0,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT dq_custom_needs_sql   CHECK (kind <> 'custom_sql' OR custom_sql IS NOT NULL),
  CONSTRAINT dq_table_needed       CHECK (kind = 'custom_sql' OR table_name IS NOT NULL),
  CONSTRAINT dq_column_needed      CHECK (kind NOT IN ('freshness_minutes','null_pct','window_count') OR column_name IS NOT NULL),
  CONSTRAINT dq_keys_needed        CHECK (kind <> 'duplicate_count' OR key_columns IS NOT NULL),
  CONSTRAINT dq_window_needed      CHECK (kind <> 'window_count' OR window_minutes IS NOT NULL),
  CONSTRAINT dq_has_threshold      CHECK (min_value IS NOT NULL OR max_value IS NOT NULL OR anomaly_k IS NOT NULL),
  CONSTRAINT dq_min_le_max         CHECK (min_value IS NULL OR max_value IS NULL OR min_value <= max_value)
);

CREATE TABLE IF NOT EXISTS dq_results (
  id         BIGSERIAL PRIMARY KEY,
  rule_id    INT NOT NULL REFERENCES dq_rules(id) ON DELETE CASCADE,
  checked_at TIMESTAMPTZ NOT NULL DEFAULT now(),
  status     TEXT NOT NULL CHECK (status IN ('ok','fail','error')),
  value      DOUBLE PRECISION,
  detail     TEXT
);
CREATE INDEX IF NOT EXISTS dq_results_rule_time ON dq_results (rule_id, checked_at DESC);
CREATE INDEX IF NOT EXISTS dq_results_time ON dq_results (checked_at);

CREATE TABLE IF NOT EXISTS dq_incidents (
  id                SERIAL PRIMARY KEY,
  rule_id           INT NOT NULL REFERENCES dq_rules(id) ON DELETE CASCADE,
  severity          TEXT NOT NULL CHECK (severity IN ('warning','critical')),
  status            TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','acked','resolved')),
  summary           TEXT NOT NULL,
  opened_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  occurrences       INT NOT NULL DEFAULT 1,
  acked_by          TEXT,
  acked_at          TIMESTAMPTZ,
  resolved_at       TIMESTAMPTZ,
  last_notified_at  TIMESTAMPTZ,
  notify_count      INT NOT NULL DEFAULT 0,
  recovery_notified BOOLEAN NOT NULL DEFAULT FALSE
);
-- at most one unresolved incident per rule, even if two workers race
CREATE UNIQUE INDEX IF NOT EXISTS dq_one_open_incident ON dq_incidents (rule_id) WHERE status IN ('open','acked');
CREATE INDEX IF NOT EXISTS dq_incidents_status ON dq_incidents (status, opened_at);
