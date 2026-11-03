-- Services a company's computers are NOT expected to keep running (an automatic-start service that normally stops by itself,
-- such as the Google or Edge updaters). One list per company, applied to every computer of that company: an ignored service
-- is still shown in the console but no longer counts toward the Services gauge or light. Staff only; every change is audited.
CREATE TABLE IF NOT EXISTS service_ignore (
  customer_slug text NOT NULL,
  service_name  text NOT NULL,          -- the short Windows service name as the agent reports it, compared case-insensitively
  display_name  text,
  added_by      text NOT NULL,
  added_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (customer_slug, service_name)
);
