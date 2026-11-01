-- BitLocker: recovery-key escrow and "turn BitLocker on" requests.
-- Recovery keys are stored ENCRYPTED (pgcrypto, passphrase = secrets/bitlocker_escrow_key, which only the portal and the
-- host-side worker can read). Without that passphrase a copy of the database is useless; keep it in the vault too.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE bitlocker_key (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_slug text NOT NULL REFERENCES customer(slug) ON DELETE CASCADE,
  host          text NOT NULL CHECK (host ~ '^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$'),     -- lower-cased computer name
  volume        text NOT NULL CHECK (volume ~ '^[A-Z]$'),
  protector_id  text NOT NULL CHECK (protector_id ~ '^\{[0-9A-Fa-f-]{36}\}$'),            -- shown in the Windows recovery screen
  recovery_enc  bytea NOT NULL,
  collected_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (customer_slug, host, volume, protector_id)
);
CREATE INDEX bitlocker_key_host_idx ON bitlocker_key(customer_slug, host);

CREATE TABLE bitlocker_request (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_slug text NOT NULL REFERENCES customer(slug) ON DELETE CASCADE,
  host          text NOT NULL CHECK (host ~ '^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$'),
  volume        text NOT NULL CHECK (volume ~ '^[A-Z]$'),
  action        text NOT NULL CHECK (action IN ('enable','escrow')),       -- enable = turn BitLocker on (and save the key); escrow = save/refresh the key only
  status        text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','running','done','failed','cancelled')),
  requested_by  text NOT NULL,
  requested_at  timestamptz NOT NULL DEFAULT now(),
  message       text,                       -- what the PC reported (never contains a key)
  finished_at   timestamptz
);
CREATE UNIQUE INDEX bitlocker_request_open_idx ON bitlocker_request(customer_slug, host, volume) WHERE status IN ('pending','running');
CREATE INDEX bitlocker_request_status_idx ON bitlocker_request(status, requested_at);
