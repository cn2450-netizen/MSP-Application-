import { createHash, timingSafeEqual } from "node:crypto";
import { q1 } from "./db";

// Agents authenticate with "<machine-uuid>.<secret>". Only a hash of the secret is stored.
export type AgentMachine = { id: string; customer_slug: string; name: string };

const buckets = new Map<string, { n: number; reset: number }>();

/** Cheap in-memory limit per machine: a stolen token or a runaway agent cannot hammer the database. */
function allow(id: string): boolean {
  const now = Date.now();
  const b = buckets.get(id);
  if (!b || b.reset < now) { buckets.set(id, { n: 1, reset: now + 60_000 }); return true; }
  return ++b.n <= 240;
}

export async function authenticateAgent(req: Request): Promise<AgentMachine | null> {
  const h = req.headers.get("authorization") || "";
  const m = /^Bearer ([0-9a-f-]{36})\.([A-Za-z0-9_-]{32,128})$/.exec(h);
  if (!m) return null;
  const row = await q1<AgentMachine & { token_hash: string | null }>(
    "SELECT id, customer_slug, name, token_hash FROM machine WHERE id = $1 AND NOT retired", [m[1]]);
  if (!row?.token_hash) return null;
  const want = Buffer.from(row.token_hash, "hex");
  const got = createHash("sha256").update(m[2]).digest();
  if (want.length !== got.length || !timingSafeEqual(want, got)) return null;
  if (!allow(row.id)) return null;
  return { id: row.id, customer_slug: row.customer_slug, name: row.name };
}

/** Reads a JSON body but refuses anything larger than maxBytes. */
export async function readJson(req: Request, maxBytes: number): Promise<unknown> {
  const len = Number(req.headers.get("content-length") || "0");
  if (len > maxBytes) throw new Error("body too large");
  const text = await req.text();
  if (text.length > maxBytes) throw new Error("body too large");
  return JSON.parse(text);
}

/** Browser-initiated POSTs must come from the portal's own origin (cookies are SameSite=Lax as well). */
export function sameOrigin(req: Request, publicUrl: string): boolean {
  const o = req.headers.get("origin");
  return !!o && o === publicUrl;
}
