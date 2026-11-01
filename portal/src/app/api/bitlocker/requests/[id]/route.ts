import { z } from "zod";
import { json } from "@/lib/api";
import { getScope } from "@/lib/session";
import { isStaffFor } from "@/lib/authz";
import { audit } from "@/lib/audit";
import { readJson, sameOrigin } from "@/lib/agentauth";
import { env } from "@/lib/env";
import { getRequest, moveRequest } from "@/lib/bitlocker";

export const dynamic = "force-dynamic";

const Body = z.object({ action: z.enum(["cancel", "retry"]) }).strict();

export async function POST(req: Request, ctx: { params: Promise<{ id: string }> }) {
  if (!sameOrigin(req, env.publicUrl)) return json({ error: "bad origin" }, 403);
  const scope = await getScope();
  if (!scope) return json({ error: "not signed in" }, 401);
  const id = (await ctx.params).id;
  const r = /^[0-9a-f-]{36}$/.test(id) ? await getRequest(id) : null;
  if (!r || !isStaffFor(scope, r.customer_slug)) return json({ error: "not found" }, 404);
  let b: z.infer<typeof Body>;
  try { b = Body.parse(await readJson(req, 200)); } catch { return json({ error: "bad request" }, 400); }
  let ok = false;
  try {
    ok = b.action === "cancel" ? await moveRequest(id, ["pending", "failed"], "cancelled") : await moveRequest(id, ["failed"], "pending");
  } catch { return json({ error: "a request for this drive is already waiting or running" }, 409); }
  if (!ok) return json({ error: "this request has already moved on" }, 409);
  await audit(scope, `bitlocker.${b.action}`, { customer: r.customer_slug, detail: { id, host: r.host, volume: r.volume } });
  return json({ ok: true });
}
