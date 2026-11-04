import { q } from "./db";

// MeshCentral's id for each computer and whether its remote agent is connected (filled every minute by scripts/mesh-sync-nodes.sh).
// Keyed like FleetRow.key: "<company slug>|<lower-case computer name>". `online` is only true while the sync is fresh: if the sync
// stops, every Connect link greys out rather than claiming computers are reachable.
export type MeshNode = { id: string; online: boolean };
const FRESH_MS = 5 * 60_000;

export async function loadNodes(): Promise<Map<string, MeshNode>> {
  try {
    const rows = await q<{ customer_slug: string; host: string; node_id: string; online: boolean; updated_at: string }>(
      "SELECT customer_slug, host, node_id, online, updated_at FROM mesh_node");
    const now = Date.now();
    return new Map(rows.map((r) => [`${r.customer_slug}|${r.host}`, { id: r.node_id, online: r.online && now - new Date(r.updated_at).getTime() < FRESH_MS }]));
  } catch {
    return new Map();                    // the table arrives with the next portal start; plain MeshCentral links until then
  }
}

// Opens that computer in MeshCentral on its Desktop tab (viewmode 11). Uses ?node= (the server picks the device before the page
// loads; MeshCentral's own "open in new window" uses it) with the short id: the server builds "node/<domain>/<id>" itself.
// The client-side ?gotonode= left a blank Desktop tab with no computer selected.
export const connectUrl = (mesh: string, nodeId: string) => `${mesh}/?node=${encodeURIComponent(nodeId.split("/")[2] ?? nodeId)}&viewmode=11`;
