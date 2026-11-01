-- A request for a computer that is switched off (or while no MeshCentral token is stored) now WAITS and is retried,
-- instead of failing: last_try spaces the retries; the worker gives up after 7 days.
ALTER TABLE bitlocker_request ADD COLUMN IF NOT EXISTS last_try timestamptz;
