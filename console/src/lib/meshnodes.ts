import { q } from "./db";

// MeshCentral's id for each computer (filled by scripts/mesh-sync-nodes.sh). Keyed like FleetRow.key: "<company slug>|<lower-case computer name>".
export async function loadNodes(): Promise<Map<string, string>> {
  try {
    const rows = await q<{ customer_slug: string; host: string; node_id: string }>("SELECT customer_slug, host, node_id FROM mesh_node");
    return new Map(rows.map((r) => [`${r.customer_slug}|${r.host}`, r.node_id]));
  } catch {
    return new Map();                    // the table arrives with the next portal start; plain MeshCentral links until then
  }
}

// viewmode 11 = remote desktop; MeshCentral signs the technician in first (same single sign-on) and then opens that computer.
export const connectUrl = (mesh: string, nodeId: string) => `${mesh}/?viewmode=11&gotonode=${encodeURIComponent(nodeId)}`;
