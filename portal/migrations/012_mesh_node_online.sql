-- Whether MeshCentral sees the computer's remote agent connected, as of mesh_node.updated_at (scripts/mesh-sync-nodes.sh, every minute).
ALTER TABLE mesh_node ADD COLUMN IF NOT EXISTS online boolean NOT NULL DEFAULT false;
