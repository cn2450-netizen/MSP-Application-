import { z } from "zod";
import { q, q1 } from "./db";
import { env } from "./env";
import { fluxRows } from "./influx";
import { visibleCustomers, type Scope } from "./authz";

// BitLocker recovery keys and "turn BitLocker on" requests. Staff only: the routes check isStaffFor() for the customer.
// Keys are encrypted in the database with pgcrypto; the passphrase never leaves the portal and the host-side worker.

export const hostName = z.string().max(64).transform((s) => s.toLowerCase()).pipe(z.string().regex(/^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$/));
export const volumeLetter = z.string().transform((s) => s.toUpperCase()).pipe(z.string().regex(/^[A-Z]$/));
export const customerSlug = z.string().regex(/^[a-z0-9][a-z0-9-]{1,30}$/);

export type KeyRow = { id: string; customer_slug: string; host: string; volume: string; protector_id: string; collected_at: string };
export type RequestRow = {
  id: string; customer_slug: string; host: string; volume: string; action: "enable" | "escrow";
  status: "pending" | "running" | "done" | "failed" | "cancelled"; requested_by: string; requested_at: string; message: string | null; finished_at: string | null;
};

const REQ_COLS = "id, customer_slug, host, volume, action, status, requested_by, requested_at, message, finished_at";

/** `customer` and `host` are optional filters; without them, everything this person may see. */
export async function listKeys(scope: Scope, customer: string | null, host: string | null): Promise<KeyRow[]> {
  const vis = visibleCustomers(scope);
  return q<KeyRow>(
    `SELECT id, customer_slug, host, volume, protector_id, collected_at FROM bitlocker_key
      WHERE ($1::text[] IS NULL OR customer_slug = ANY($1)) AND ($2::text IS NULL OR customer_slug = $2) AND ($3::text IS NULL OR host = $3)
      ORDER BY customer_slug, host, volume, collected_at DESC LIMIT 500`,
    [vis, customer, host],
  );
}

export async function listRequests(scope: Scope, customer: string | null, host: string | null): Promise<RequestRow[]> {
  const vis = visibleCustomers(scope);
  return q<RequestRow>(
    `SELECT ${REQ_COLS} FROM bitlocker_request
      WHERE ($1::text[] IS NULL OR customer_slug = ANY($1)) AND ($2::text IS NULL OR customer_slug = $2) AND ($3::text IS NULL OR host = $3)
      ORDER BY requested_at DESC LIMIT 30`,
    [vis, customer, host],
  );
}

export async function getKey(id: string) {
  return q1<KeyRow>("SELECT id, customer_slug, host, volume, protector_id, collected_at FROM bitlocker_key WHERE id = $1", [id]);
}

/** The recovery password itself. Only call this after the route has checked staff access and written the audit entry. */
export async function decryptKey(id: string): Promise<string | null> {
  const r = await q1<{ k: string }>("SELECT pgp_sym_decrypt(recovery_enc, $2) AS k FROM bitlocker_key WHERE id = $1", [id, env.bitlockerKey]);
  return r?.k ?? null;
}

export async function customerExists(slug: string) {
  return !!(await q1("SELECT 1 FROM customer WHERE slug = $1", [slug]));
}

export async function getRequest(id: string) {
  return q1<RequestRow>(`SELECT ${REQ_COLS} FROM bitlocker_request WHERE id = $1`, [id]);
}

/** null when a request for that volume is already waiting or running. */
export async function createRequest(customer: string, host: string, volume: string, action: "enable" | "escrow", by: string) {
  const r = await q1<{ id: string }>(
    `INSERT INTO bitlocker_request(customer_slug, host, volume, action, requested_by) VALUES ($1,$2,$3,$4,$5)
     ON CONFLICT DO NOTHING RETURNING id`, [customer, host, volume, action, by]);
  return r?.id ?? null;
}

/** Moves a request to a new status if it is in one of the `from` states. A retry (back to pending) can hit the one-open-request rule. */
export async function moveRequest(id: string, from: string[], to: string) {
  const r = await q(
    `UPDATE bitlocker_request SET status = $3,
            message = CASE WHEN $3 = 'pending' THEN NULL ELSE message END,
            last_try = CASE WHEN $3 = 'pending' THEN NULL ELSE last_try END,
            finished_at = CASE WHEN $3 = 'pending' THEN NULL ELSE now() END
      WHERE id = $1 AND status = ANY($2) RETURNING id`, [id, from, to]);
  return r.length > 0;
}

export type Drive = { volume: string; label: string; protected: boolean; percent: number; status: string; key_saved: boolean };
export type Computer = { customer_slug: string; customer_name: string; host: string; name: string; site_slug: string; last_seen: string | null; drives: Drive[] };

const slugOk = (s: string) => /^[a-z0-9][a-z0-9-]{1,30}$/.test(s);
const cache = new Map<string, { at: number; rows: Omit<Computer, "customer_name">[] }>();

/** One customer's computers and drives, straight from InfluxDB (cached for 30 s so the page is quick). */
async function influxComputers(slug: string) {
  const hit = cache.get(slug);
  if (hit && Date.now() - hit.at < 30_000) return hit.rows;
  const bucket = `cust_${slug}`;          // slug was validated by the caller
  const [hosts, vols] = await Promise.all([
    fluxRows(`from(bucket: "${bucket}") |> range(start: -7d)
      |> filter(fn: (r) => r._measurement == "cpu" and r._field == "usage_idle" and r.cpu == "cpu-total")
      |> last() |> keep(columns: ["host", "site", "_time"]) |> group()`),
    fluxRows(`from(bucket: "${bucket}") |> range(start: -2h)
      |> filter(fn: (r) => r._measurement == "bitlocker" and (r._field == "protection_status" or r._field == "encryption_percentage" or r._field == "volume_status"))
      |> last() |> drop(columns: ["_time", "_start", "_stop", "_measurement"])
      |> pivot(rowKey: ["host", "volume"], columnKey: ["_field"], valueColumn: "_value") |> group()`),
  ]);
  const keys = await q<{ host: string; volume: string }>("SELECT DISTINCT host, volume FROM bitlocker_key WHERE customer_slug = $1", [slug]);
  const saved = new Set(keys.map((k) => `${k.host}|${k.volume}`));
  const byHost = new Map<string, Omit<Computer, "customer_name">>();
  const get = (host: string, site: string) => {
    const k = host.toLowerCase();
    if (!byHost.has(k)) byHost.set(k, { customer_slug: slug, host: k, name: host, site_slug: /^[a-z0-9][a-z0-9-]{0,30}$/.test(site) ? site : "main", last_seen: null, drives: [] });
    return byHost.get(k)!;
  };
  for (const r of hosts) if (r.host) get(r.host, r.site).last_seen = r._time || null;
  for (const r of vols) {
    if (!r.host || !/^[A-Z]$/.test(r.volume)) continue;
    const c = get(r.host, r.site);
    c.drives.push({ volume: r.volume, label: r.name || `${r.volume}:`, protected: r.protection_status === "1", percent: Number(r.encryption_percentage) || 0, status: r.volume_status || "Unknown", key_saved: saved.has(`${c.host}|${r.volume}`) });
  }
  const rows = [...byHost.values()].map((c) => ({ ...c, drives: c.drives.sort((a, b) => a.volume.localeCompare(b.volume)) }));
  cache.set(slug, { at: Date.now(), rows });
  return rows;
}

/** Every computer the monitoring agent reports, for the customers this person may see. A customer whose data cannot be read is skipped, not fatal. */
export async function listComputers(scope: Scope, customers: { slug: string; name: string }[]): Promise<{ computers: Computer[]; failed: string[] }> {
  const vis = visibleCustomers(scope);
  const allowed = customers.filter((c) => slugOk(c.slug) && (vis === null || vis.includes(c.slug)));
  const failed: string[] = [];
  const parts = await Promise.all(allowed.map(async (c) => {
    try { return (await influxComputers(c.slug)).map((r) => ({ ...r, customer_name: c.name })); }
    catch { failed.push(c.name); return []; }
  }));
  return { computers: parts.flat().sort((a, b) => a.customer_name.localeCompare(b.customer_name) || a.host.localeCompare(b.host)), failed };
}

/** One short label for a drive: On / Encrypting 43% / Suspended / Off. */
export function driveState(v: { protected: boolean; percent: number; status: string }): { key: "ok" | "warn" | "bad"; label: string } {
  if (v.status === "FullyEncrypted") return v.protected ? { key: "ok", label: "On" } : { key: "warn", label: "Suspended" };
  if (v.status === "FullyDecrypted") return { key: "bad", label: "Off" };
  if (/Encryption/i.test(v.status)) return { key: "warn", label: `Encrypting ${Math.round(v.percent)}%` };
  if (/Decryption/i.test(v.status)) return { key: "warn", label: `Decrypting ${Math.round(100 - v.percent)}%` };
  return { key: "warn", label: v.status };
}
