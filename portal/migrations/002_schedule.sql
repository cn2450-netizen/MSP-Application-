-- When the nightly backup runs, as chosen in the portal. No row = whatever the installer was built with.
-- Times are the computer's own local time.
CREATE TABLE schedule (
  machine_id  uuid PRIMARY KEY REFERENCES machine(id) ON DELETE CASCADE,
  days        jsonb NOT NULL CHECK (jsonb_typeof(days) = 'array' AND jsonb_array_length(days) BETWEEN 1 AND 7),   -- 0 = Sunday ... 6 = Saturday
  at_time     text  NOT NULL CHECK (at_time ~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'),
  version     integer NOT NULL DEFAULT 1,
  updated_by  text NOT NULL,
  updated_at  timestamptz NOT NULL DEFAULT now()
);
