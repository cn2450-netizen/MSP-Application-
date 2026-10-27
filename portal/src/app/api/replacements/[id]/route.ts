import { z } from "zod";
import { json } from "@/lib/api";
import { getScope } from "@/lib/session";
import { getReplacement, moveReplacement } from "@/lib/data";
import { isStaffFor } from "@/lib/authz";
import { audit } from "@/lib/audit";
import { readJson, sameOrigin } from "@/lib/agentauth";
import { env } from "@/lib/env";

export const dynamic = "force-dynamic";

const Body = z.object({ action: z.enum(["approve", "reject", "cancel", "retry"]) }).strict();

// Decide on a replacement request. The person who asked cannot approve it (unless the operator has explicitly allowed
// that for a one-technician lab): that second pair of eyes is the point.
export async function POST(req: Request, ctx: { params: Promise<{ id: string }> }) {
  if (!sameOrigin(req, env.publicUrl)) return json({ error: "bad origin" }, 403);
  const scope = await getScope();
  if (!scope) return json({ error: "not signed in" }, 401);
  const rep = await getReplacement(scope, (await ctx.params).id);
  if (!rep) return json({ error: "not found" }, 404);
  if (!isStaffFor(scope, rep.customer_slug)) return json({ error: "not allowed" }, 403);
  let body: z.infer<typeof Body>;
  try { body = Body.parse(await readJson(req, 500)); } catch { return json({ error: "bad request" }, 400); }

  const own = rep.requested_by === scope.username;
  let ok = false;
  if (body.action === "approve" || body.action === "reject") {
    if (body.action === "approve" && own && !env.allowSelfApprove) return json({ error: "another technician has to approve this request" }, 403);
    ok = await moveReplacement(rep.id, ["pending"], body.action === "approve" ? "approved" : "rejected", scope.username);
  } else if (body.action === "cancel") {
    if (!own && !scope.admin) return json({ error: "only the person who asked, or an administrator, can cancel" }, 403);
    ok = await moveReplacement(rep.id, ["pending", "approved", "failed"], "cancelled", scope.username);
  } else {
    ok = await moveReplacement(rep.id, ["failed"], "approved", null);       // try again with the approval already given
  }
  if (!ok) return json({ error: "this request has already moved on" }, 409);
  await audit(scope, `replace.${body.action}`, { customer: rep.customer_slug, machineId: rep.machine_id, detail: { id: rep.id, device: rep.new_device } });
  return json({ ok: true });
}
