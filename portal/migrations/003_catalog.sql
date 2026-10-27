-- Catalog of what each backup contains, so the portal can browse and search without asking the computer.
-- Filled by scripts/backup-catalog.sh (on the backup host, which can read the repositories); the portal only reads it.
-- It holds NAMES, SIZES and DATES only: never file contents and never backup passwords.
CREATE EXTENSION IF NOT EXISTS pg_trgm;

CREATE TABLE catalog_snapshot (
  seq         bigserial PRIMARY KEY,
  machine_id  uuid NOT NULL REFERENCES machine(id) ON DELETE CASCADE,
  snapshot_id text NOT NULL CHECK (snapshot_id ~ '^[0-9a-f]{64}$'),
  taken_at    timestamptz NOT NULL,
  paths       jsonb NOT NULL DEFAULT '[]'::jsonb,
  indexed_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (machine_id, snapshot_id)
);
CREATE INDEX catalog_snapshot_time_idx ON catalog_snapshot(machine_id, taken_at DESC);

-- One row per distinct version of a file or folder; snaps lists the catalog_snapshot.seq values that contain it.
-- Folders ignore size and date (kind 'd', size 0, mtime = epoch) so they are stored once.
CREATE TABLE catalog_file (
  machine_id  uuid NOT NULL REFERENCES machine(id) ON DELETE CASCADE,
  parent      text NOT NULL,
  name        text NOT NULL,
  kind        char(1) NOT NULL CHECK (kind IN ('f','d')),
  size        bigint NOT NULL DEFAULT 0,
  mtime       timestamptz NOT NULL DEFAULT 'epoch',
  snaps       bigint[] NOT NULL,
  PRIMARY KEY (machine_id, parent, name, kind, size, mtime)
);
CREATE INDEX catalog_file_name_idx ON catalog_file USING gin (name gin_trgm_ops);
