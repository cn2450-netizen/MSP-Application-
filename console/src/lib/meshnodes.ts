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

// Opens that computer in MeshCentral on its Desktop tab (viewmode 11). Uses ?node= (the server picks the device before the page
// loads; MeshCentral's own "open in new window" uses it) with the short id: the server builds "node/<domain>/<id>" itself.
// The client-side ?gotonode= left a blank Desktop tab with no computer selected.
export const connectUrl = (mesh: string, nodeId: string) => `${mesh}/?node=${encodeURIComponent(nodeId.split("/")[2] ?? nodeId)}&viewmode=11`;
