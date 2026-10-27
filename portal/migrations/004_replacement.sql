-- "Replace this computer": a technician asks for a machine's backup identity to move to a new computer, a DIFFERENT
-- person approves, and a script on the backup host (which holds the credentials; the portal never does) carries it out.
CREATE TABLE replacement (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id    uuid NOT NULL REFERENCES machine(id) ON DELETE CASCADE,
  new_device    text NOT NULL CHECK (new_device ~ '^[A-Za-z0-9]([A-Za-z0-9-]{0,28}[A-Za-z0-9])?$'),
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','approved','running','done','failed','rejected','cancelled')),
  requested_by  text NOT NULL,
  requested_at  timestamptz NOT NULL DEFAULT now(),
  decided_by    text,
  decided_at    timestamptz,
  message       text,                       -- what the host-side script reported (never contains secrets)
  finished_at   timestamptz
);
-- one open request per machine
CREATE UNIQUE INDEX replacement_open_idx ON replacement(machine_id) WHERE status IN ('pending','approved','running');
CREATE INDEX replacement_status_idx ON replacement(status, requested_at);
