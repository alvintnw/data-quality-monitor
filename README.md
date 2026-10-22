# Data Quality Monitor for n8n

Define data quality rules as rows in PostgreSQL. n8n runs them on a schedule as read-only queries, keeps the history, opens an **incident** after N consecutive failures, and sends a Telegram alert with **Acknowledge / Snooze** buttons. Recoveries are announced and a daily report summarizes the state of your data.

Adding or changing a check is an `INSERT`/`UPDATE` on `dq_rules`. No workflow editing needed.

## Features

- **Six check types**: row count, freshness (minutes since the newest row), null percentage, duplicate keys, rows in a recent time window, and custom SQL returning one number.
- **Thresholds and anomaly detection**: `min_value` / `max_value`, plus optional `anomaly_k`, a robust z-score (median and MAD of the last 30 values) for metrics like hourly volume that have no fixed limit. It learns for 10 samples before it alerts.
- **Fewer false alarms**: `min_failures` requires N consecutive failures before an incident opens.
- **Incident lifecycle**: one open incident per rule (enforced by a partial unique index), occurrence counting, automatic resolution when the check passes again, and a recovery message.
- **Telegram actions**: Acknowledge (stops reminders), Snooze 1h / 24h (silences the rule, alert returns afterwards if still failing). Only user ids in `ALLOWED_USER_IDS` can press buttons.
- **Reminders**: per-rule `reminder_minutes` for unacknowledged incidents.
- **Daily report** at 08:00: rules failing, 24h pass rate, open incidents, noisiest rules, and a warning when rules have stopped running on time (a dead monitor is the worst failure).
- **Housekeeping**: results older than 90 days are deleted daily.
- Parallel-safe: due rules and notifications are claimed with `FOR UPDATE SKIP LOCKED`, so overlapping runs never double-check or double-alert.

## How it works

```
Check Schedule (*/5) ─► Load Due Rules ─► Build Check Query ─► Run Check ─► Evaluate Results ─► Record Result
                        (claims rules)    (validates, builds   (read-only    (thresholds,        (result row, rule state,
                                           one SELECT each)     credential)   anomaly)            open / resolve incident)

Notify Schedule (2-59/5) ─► Claim Notifications ─► Format Alerts ─► Needs Buttons? ─► Send Alert (Ack / 1h / 24h)
                                                                                  └► Send Recovery

Telegram Trigger (callback_query) ─► Parse Callback ─► Authorized? ─► Apply Callback ─► Edit Alert Message ─► Answer Callback
Daily Schedule (08:00) ─► Cleanup Old Results ─► Digest Stats ─► Format Digest ─► Send Digest
Error Trigger ─► Format Error ─► Send Error Alert
```

Checking and notifying are separate flows on purpose: recording a result never depends on Telegram being up, and notifications are claimed in the database so each one is sent once.

## Setup

1. **State tables.** Run `sql/schema.sql` on the database n8n will use for state (safe to re-run).
2. **Read-only role.** Edit and run `sql/readonly_role.sql` on the database you want to monitor. It creates `dq_reader` with `SELECT` only and a 30 s statement timeout. The state database and the monitored database can be the same or different.
3. **Credentials in n8n** (three):
   - Postgres (state): read/write on the `dq_*` tables. Used by every Postgres node except `Run Check`.
   - Postgres (read-only): the `dq_reader` role. Used **only** by `Run Check`.
   - Telegram: your bot token.
4. **Import** `workflows/data_quality_monitor.json` and select the credentials (the 15 `REPLACE_ID` entries).
5. **Replace placeholders**:
   - `REPLACE_WITH_ALERT_CHAT_ID`: chat id for alerts, report and errors (4 Telegram nodes).
   - `REPLACE_WITH_TELEGRAM_USER_ID` in the `Parse Callback` node (`ALLOWED_USER_IDS`): who may press buttons. The placeholder authorizes nobody.
6. **Add rules**, for example `sql/example_rules.sql` adapted to your tables.
7. **Set the Error Workflow** of this workflow to itself (Settings → Error workflow) so failures of the monitor are reported.
8. **Activate.** Use *Manual Check* first to try it. Test the Telegram trigger once with a real alert; n8n registers the webhook when the workflow is active.

## Defining rules

| Column | Meaning |
|---|---|
| `kind` | `row_count`, `freshness_minutes`, `null_pct`, `duplicate_count`, `window_count`, `custom_sql` |
| `table_name` | `orders` or `public.orders` (identifiers only) |
| `column_name` | timestamp column for freshness / window_count, checked column for null_pct |
| `key_columns` | up to 5 comma-separated columns for `duplicate_count` |
| `where_clause` | optional plain condition applied to the table (no subqueries) |
| `window_minutes` | look-back window for `window_count` |
| `custom_sql` | one `SELECT` / `WITH … SELECT` returning one numeric column named `value` |
| `min_value`, `max_value` | the check fails when the measured value is outside |
| `anomaly_k` | also fail when the value deviates more than *k* robust deviations from recent history (3–5 is typical) |
| `severity` | `warning` or `critical` (critical alerts are sent first) |
| `interval_minutes` | how often to run (the scheduler wakes every 5 minutes, so the effective minimum is 5) |
| `min_failures` | consecutive failures before an incident opens |
| `reminder_minutes` | repeat the alert for unacknowledged incidents; `0` = never |

What each kind measures:

| kind | value |
|---|---|
| `row_count` | number of rows |
| `freshness_minutes` | minutes since `max(column)`; an empty table fails |
| `null_pct` | percentage of NULLs in the column (0 for an empty table) |
| `duplicate_count` | number of key combinations that appear more than once |
| `window_count` | rows whose `column` is within the last `window_minutes` |
| `custom_sql` | the `value` column of your query |

Useful operations:

```sql
UPDATE dq_rules SET enabled = FALSE WHERE name = 'orders: table not empty';  -- pause a rule
UPDATE dq_rules SET snooze_until = now() + interval '2 days' WHERE id = 3;    -- silence alerts
SELECT * FROM dq_results WHERE rule_id = 3 ORDER BY checked_at DESC LIMIT 50; -- history
SELECT * FROM dq_incidents WHERE status <> 'resolved';                        -- open incidents
```

## Security model

- Rules are code. **Only people who can write to `dq_rules` can define checks**; treat that table like any other privileged config.
- Identifiers are validated (`[A-Za-z_][A-Za-z0-9_$]*`) and double-quoted. `where_clause` and `custom_sql` reject semicolons, comments, unbalanced quotes/parentheses, DML/DDL keywords, `pg_*`, `lo_*`, `dblink*`, and (for `where_clause`) subqueries. Custom SQL is wrapped in a sub-select, which makes PostgreSQL itself refuse data-modifying CTEs.
- This screening is a guard rail, not a sandbox. The real protection is the **read-only role with a statement timeout** used by `Run Check`. Do not point that credential at a role that can write or read secrets.
- A literal such as `status = 'delete'` is rejected because of the keyword filter; compare with a different spelling or use `custom_sql` with a safe constant.
- Rejected rules never reach the database: they are recorded as `error` with the reason, which also opens an incident so you notice.
- Telegram buttons are restricted to `ALLOWED_USER_IDS` and callback data must match `dq:(ack|snz1|snz24):<id>` exactly.

## Behavior notes and limits

- **Claim, then run.** Due rules are claimed by moving `next_run_at` forward before they run. If the workflow crashes mid-run, those rules wait for their next interval.
- **Notifications are at-most-once.** An alert is marked as sent when it is claimed. If Telegram is down at that moment, the alert is lost unless the rule has `reminder_minutes > 0`; set reminders on critical rules.
- **Alerts lag up to 5 minutes** behind a failed check (separate notify schedule).
- **Snooze** silences notifications, not checking. Results and incidents keep updating. When the snooze ends and the incident is still open, you get the alert again.
- **Anomaly baseline adapts.** History is the last 30 measured values including failing ones, so after a lasting level change the baseline follows within about 15 runs. Pair anomaly rules with a fixed `min_value` for hard floors (for example "orders never drop to 0").
- **Time zones.** Freshness uses `now() - max(column)`. For `timestamp without time zone` columns the session time zone of the read-only role is used; set it with `ALTER ROLE dq_reader SET timezone = 'UTC'` if your data is stored in UTC.
- Up to 50 rules are claimed per run and 20 alerts per notify run; the rest follow on the next run.
- Alert messages edited after a button press lose bold formatting (Telegram returns plain text).

## Testing status

The Code nodes and every SQL statement from this workflow were tested outside n8n: the node source was executed with mocked inputs and the queries were run against a real PostgreSQL engine (PGlite) through full cycles (load → build → measure → evaluate → record → notify → button → recover), including injection attempts, anomaly detection, snooze/ack, exactly-once claiming, and cleanup. **Not tested here:** a live n8n instance, the Telegram API (message format, button callbacks, edit message), and truly concurrent workers. Run *Manual Check* and a deliberately failing rule on your own setup before relying on it.

## Files

```
workflows/data_quality_monitor.json   n8n workflow (32 nodes)
sql/schema.sql                        dq_rules, dq_results, dq_incidents
sql/readonly_role.sql                 read-only role with statement timeout
sql/example_rules.sql                 example rules for an orders table
```

## License

MIT. Add a `LICENSE` file to your repository.
