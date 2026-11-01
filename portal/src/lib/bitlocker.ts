import { z } from "zod";
import { q, q1 } from "./db";
import { env } from "./env";
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
            finished_at = CASE WHEN $3 = 'pending' THEN NULL ELSE now() END
      WHERE id = $1 AND status = ANY($2) RETURNING id`, [id, from, to]);
  return r.length > 0;
}
