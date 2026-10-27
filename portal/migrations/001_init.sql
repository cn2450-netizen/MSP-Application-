-- Portal schema. The portal holds METADATA only: no backup passwords, no file contents.
CREATE TABLE customer (
  slug        text PRIMARY KEY CHECK (slug ~ '^[a-z0-9][a-z0-9-]{1,30}$'),
  name        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE site (
  customer_slug text NOT NULL REFERENCES customer(slug) ON DELETE CASCADE,
  slug          text NOT NULL CHECK (slug ~ '^[a-z0-9][a-z0-9-]{0,30}$'),
  created_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (customer_slug, slug)
);

CREATE TABLE machine (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_slug   text NOT NULL,
  site_slug       text NOT NULL,
  name            text NOT NULL CHECK (name ~ '^[a-z0-9]([a-z0-9-]{0,28}[a-z0-9])?$'),
  display_name    text,
  repo_user       text NOT NULL UNIQUE,            -- the restic server login / repository directory
  token_hash      text,                            -- sha256 of the agent's secret; the secret itself is never stored
  backup_enabled  boolean NOT NULL DEFAULT true,
  retired         boolean NOT NULL DEFAULT false,
  agent_version   text,
  os_desc         text,
  last_seen       timestamptz,
  interactive_until timestamptz,                   -- a person has the browse screen open: agent polls fast until then
  created_at      timestamptz NOT NULL DEFAULT now(),
  FOREIGN KEY (customer_slug, site_slug) REFERENCES site(customer_slug, slug) ON DELETE CASCADE,
  UNIQUE (customer_slug, site_slug, name)
);
CREATE INDEX machine_customer_idx ON machine(customer_slug);

-- What to back up. No row = whatever the installer was built with.
CREATE TABLE policy (
  machine_id    uuid PRIMARY KEY REFERENCES machine(id) ON DELETE CASCADE,
  include_paths jsonb NOT NULL CHECK (jsonb_typeof(include_paths) = 'array' AND jsonb_array_length(include_paths) BETWEEN 1 AND 200),
  version       integer NOT NULL DEFAULT 1,
  updated_by    text NOT NULL,
  updated_at    timestamptz NOT NULL DEFAULT now()
);

-- Last backup result, as reported by the agent.
CREATE TABLE backup_status (
  machine_id      uuid PRIMARY KEY REFERENCES machine(id) ON DELETE CASCADE,
  result          text,                            -- ok | partial | failed
  last_run        timestamptz,
  last_success    timestamptz,
  duration_s      integer,
  files_new       bigint,
  data_added      bigint,
  bytes_processed bigint,
  snapshot_id     text,
  message         text,
  progress        jsonb,                           -- live progress of a running backup (percent_done, files_done, ...)
  updated_at      timestamptz NOT NULL DEFAULT now()
);

-- Work for an agent to do. The agent only ever EXECUTES these; the portal validates every parameter first.
CREATE TABLE job (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  machine_id    uuid NOT NULL REFERENCES machine(id) ON DELETE CASCADE,
  type          text NOT NULL CHECK (type IN ('list_dirs','backup_now','list_snapshots','ls_snapshot','find','restore')),
  params        jsonb NOT NULL DEFAULT '{}'::jsonb,
  status        text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','running','done','failed','expired')),
  progress      jsonb,
  result        jsonb,
  error         text,
  requested_by  text NOT NULL,
  requested_at  timestamptz NOT NULL DEFAULT now(),
  started_at    timestamptz,
  updated_at    timestamptz NOT NULL DEFAULT now(),
  finished_at   timestamptz,
  expires_at    timestamptz NOT NULL
);
CREATE INDEX job_machine_idx ON job(machine_id, status);

CREATE TABLE audit (
  id            bigserial PRIMARY KEY,
  at            timestamptz NOT NULL DEFAULT now(),
  actor         text NOT NULL,
  action        text NOT NULL,
  customer_slug text,
  machine_id    uuid,
  detail        jsonb NOT NULL DEFAULT '{}'::jsonb,
  ip            text
);
CREATE INDEX audit_customer_idx ON audit(customer_slug, at DESC);

-- Browser sessions. Only a hash of the cookie value is stored.
CREATE TABLE session (
  id_hash     text PRIMARY KEY,
  sub         text NOT NULL,
  username    text NOT NULL,
  name        text,
  groups      jsonb NOT NULL DEFAULT '[]'::jsonb,
  created_at  timestamptz NOT NULL DEFAULT now(),
  last_seen   timestamptz NOT NULL DEFAULT now(),
  expires_at  timestamptz NOT NULL
);
