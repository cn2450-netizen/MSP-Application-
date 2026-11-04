-- MeshCentral's id for each computer, so the console's Remote access page can open a session on that exact computer.
-- Filled by scripts/mesh-sync-nodes.sh (every auto-deploy run); the console only reads it.
CREATE TABLE IF NOT EXISTS mesh_node (
  customer_slug text NOT NULL,
  host          text NOT NULL,          -- lower-case computer name, as the monitoring agent reports it
  node_id       text NOT NULL,          -- "node//..." as MeshCentral names it
  updated_at    timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (customer_slug, host)
);
