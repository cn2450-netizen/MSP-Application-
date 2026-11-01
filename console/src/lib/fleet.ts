import type { Scope } from "./authz";
import { listMachines, health, type MachineRow } from "./data";
import { driveState, listComputers, type Drive } from "./bitlocker";
import type { View } from "./view";

export type FleetDrive = Drive & { state: ReturnType<typeof driveState> };
export type FleetRow = {
  key: string; slug: string; customerName: string; host: string; name: string; site: string;
  lastSeen: string | null; drives: FleetDrive[]; m?: MachineRow;
  online: boolean;                 // the monitoring agent reported in the last 10 minutes
  backup: ReturnType<typeof health> | null;
};

const ONLINE_MS = 10 * 60_000;

/**
 * Every computer in the current view: what monitoring (InfluxDB) reports, merged with what the backup system knows.
 * One list for the overview, the Computers page and the detail page, so they cannot disagree.
 */
export async function loadFleet(scope: Scope, view: View): Promise<{ rows: FleetRow[]; failed: string[] }> {
  const inView = (c: string, s: string) => (!view.customer || c === view.customer) && (!view.site || s === view.site);
  const machines = (await listMachines(scope)).filter((m) => inView(m.customer_slug, m.site_slug));
  const byKey = new Map(machines.map((m) => [`${m.customer_slug}|${m.name.toLowerCase()}`, m]));
  const { computers, failed } = await listComputers(scope, view.customers.filter((c) => !view.customer || c.slug === view.customer));

  const mk = (base: Omit<FleetRow, "online" | "backup">): FleetRow => ({
    ...base,
    online: !!base.lastSeen && Date.now() - new Date(base.lastSeen).getTime() < ONLINE_MS,
    backup: base.m ? health(base.m) : null,
  });
  const rows: FleetRow[] = computers.filter((c) => inView(c.customer_slug, c.site_slug)).map((c) => mk({
    key: `${c.customer_slug}|${c.host}`, slug: c.customer_slug, customerName: c.customer_name, host: c.host, name: c.name, site: c.site_slug,
    lastSeen: c.last_seen, drives: c.drives.map((d) => ({ ...d, state: driveState(d) })), m: byKey.get(`${c.customer_slug}|${c.host}`),
  }));
  const seen = new Set(rows.map((r) => r.key));
  // computers set up for backup that have sent no monitoring data
  for (const m of machines) {
    const key = `${m.customer_slug}|${m.name.toLowerCase()}`;
    if (seen.has(key)) continue;
    rows.push(mk({ key, slug: m.customer_slug, customerName: m.customer_name, host: m.name.toLowerCase(), name: m.display_name || m.name, site: m.site_slug, lastSeen: null, drives: [], m }));
  }
  return { rows, failed };
}

export const notFullyEncrypted = (r: FleetRow) => r.drives.some((d) => d.state.key !== "ok");
export const fullyEncrypted = (r: FleetRow) => r.drives.length > 0 && !notFullyEncrypted(r);
export const keyMissing = (r: FleetRow) => r.drives.some((d) => d.state.key === "ok" && !d.key_saved);
export const backupNeedsLook = (r: FleetRow) => !!r.backup && (r.backup.key === "warn" || r.backup.key === "bad");
export const offlineLong = (r: FleetRow) => !r.lastSeen || Date.now() - new Date(r.lastSeen).getTime() > 24 * 3600_000;
