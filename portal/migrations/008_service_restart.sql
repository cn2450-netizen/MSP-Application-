-- "Restart this Windows service" requests made in the console and carried out on the computer through MeshCentral by
-- scripts/service-restart-executor.sh (timer: scripts/install-service-restart.sh). Staff only; every request is also audited.
CREATE TABLE IF NOT EXISTS service_restart (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_slug text NOT NULL,
  host          text NOT NULL CHECK (host ~ '^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$'),
  service_name  text NOT NULL CHECK (service_name ~ '^[A-Za-z0-9_.$-]{1,80}$'),     -- the short Windows service name
  display_name  text,
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','running','done','failed','cancelled')),
  requested_by  text NOT NULL,
  requested_at  timestamptz NOT NULL DEFAULT now(),
  last_try      timestamptz,
  message       text,
  finished_at   timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS service_restart_open_idx ON service_restart(customer_slug, host, service_name) WHERE status IN ('pending','running');
CREATE INDEX IF NOT EXISTS service_restart_status_idx ON service_restart(status, requested_at);
CREATE INDEX IF NOT EXISTS service_restart_host_idx ON service_restart(customer_slug, host, requested_at DESC);
