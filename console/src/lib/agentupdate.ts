import { q } from "./db";

// Computers the monitoring auto-updater gave up on (scripts/monitoring-autoupdate.sh) and that need a person.
// Rows are keyed like FleetRow.key: "<company slug>|<lower-case computer name>".
export type Stuck = { failures: number; reason: string; since: string | null };

export async function loadStuck(): Promise<Map<string, Stuck>> {
  try {
    const rows = await q<{ customer_slug: string; host: string; failures: number; last_result: string | null; flagged_at: string | null }>(
      "SELECT customer_slug, host, failures, last_result, flagged_at FROM agent_update WHERE flagged");
    return new Map(rows.map((r) => [`${r.customer_slug}|${r.host}`, { failures: r.failures, reason: r.last_result ?? "", since: r.flagged_at }]));
  } catch {
    return new Map();                    // the table arrives with the next portal start; no flags until then
  }
}
