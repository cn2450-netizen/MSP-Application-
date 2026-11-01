import { z } from "zod";
import { json } from "@/lib/api";
import { getScope } from "@/lib/session";
import { isStaffFor } from "@/lib/authz";
import { audit } from "@/lib/audit";
import { readJson, sameOrigin } from "@/lib/agentauth";
import { env } from "@/lib/env";
import { decryptKey, getKey } from "@/lib/bitlocker";

export const dynamic = "force-dynamic";

const Body = z.object({ reason: z.string().trim().min(3).max(200).refine((s) => !/[\u0000-\u001f]/.test(s)) }).strict();

// Showing a recovery key is the one place a secret leaves the system, so it needs a stated reason and is always logged.
export async function POST(req: Request, ctx: { params: Promise<{ id: string }> }) {
  if (!sameOrigin(req, env.publicUrl)) return json({ error: "bad origin" }, 403);
  const scope = await getScope();
  if (!scope) return json({ error: "not signed in" }, 401);
  const id = (await ctx.params).id;
  const k = /^[0-9a-f-]{36}$/.test(id) ? await getKey(id) : null;
  if (!k || !isStaffFor(scope, k.customer_slug)) return json({ error: "not found" }, 404);
  let b: z.infer<typeof Body>;
  try { b = Body.parse(await readJson(req, 500)); } catch { return json({ error: "please give a short reason" }, 400); }
  await audit(scope, "bitlocker.key.reveal", { customer: k.customer_slug, detail: { host: k.host, volume: k.volume, protector: k.protector_id, reason: b.reason } });
  const key = await decryptKey(id);
  if (!key) return json({ error: "could not decrypt" }, 500);
  const res = json({ key, protector: k.protector_id });
  res.headers.set("cache-control", "no-store");
  return res;
}
