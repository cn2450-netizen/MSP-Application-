-- The monitoring data names a service by its display name ("Intel(R) TPM Provisioning Service"), which has spaces and
-- brackets, so the restart request must accept those. The characters that could break a command line stay excluded.
ALTER TABLE service_restart DROP CONSTRAINT IF EXISTS service_restart_service_name_check;
ALTER TABLE service_restart ADD CONSTRAINT service_restart_service_name_check CHECK (service_name ~ '^[A-Za-z0-9 ._()$#+/:@-]{1,120}$');
