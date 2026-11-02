-- One row per computer the monitoring auto-updater (scripts/monitoring-autoupdate.sh) has tried to update. It keeps the
-- attempts per day and failures in a row, and flags a computer after repeated failures so a person looks at it.
CREATE TABLE IF NOT EXISTS agent_update (
  customer_slug  text        NOT NULL,
  host           text        NOT NULL,                  -- lower-case computer name
  attempt_day    date        NOT NULL DEFAULT current_date,
  attempts_today integer     NOT NULL DEFAULT 0,
  failures       integer     NOT NULL DEFAULT 0,        -- failures in a row
  last_try       timestamptz,
  last_result    text,
  flagged        boolean     NOT NULL DEFAULT false,    -- needs manual attention: no further automatic attempts
  flagged_at     timestamptz,
  PRIMARY KEY (customer_slug, host)
);
