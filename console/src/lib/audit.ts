import { q } from "./db";
import { clientIp } from "./session";
import type { Scope } from "./authz";

/** Every action that reads or changes customer backup data leaves a trace: who, what, when, from where. */
export async function audit(actor: Scope | string, action: string, opts: { customer?: string; machineId?: string; detail?: object } = {}) {
  let ip = "";
  try { ip = await clientIp(); } catch { /* outside a request */ }
  await q(`INSERT INTO audit(actor, action, customer_slug, machine_id, detail, ip) VALUES ($1,$2,$3,$4,$5,$6)`,
    [typeof actor === "string" ? actor : actor.username, action, opts.customer ?? null, opts.machineId ?? null, JSON.stringify(opts.detail ?? {}), ip]);
}
