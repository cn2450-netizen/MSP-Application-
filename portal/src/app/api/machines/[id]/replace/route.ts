import { z } from "zod";
import { withMachine, json } from "@/lib/api";
import { requestReplacement } from "@/lib/data";
import { isStaffFor } from "@/lib/authz";
import { audit } from "@/lib/audit";
import { readJson } from "@/lib/agentauth";

export const dynamic = "force-dynamic";

const Body = z.object({ device: z.string().regex(/^[A-Za-z0-9]([A-Za-z0-9-]{0,28}[A-Za-z0-9])?$/) }).strict();

// A technician asks for this machine's backup identity to move to a new computer. Nothing happens until a different
// person approves it (POST /api/replacements/<id>).
export async function POST(req: Request, ctx: { params: Promise<{ id: string }> }) {
  const r = await withMachine(req, (await ctx.params).id, { write: true });
  if (r instanceof Response) return r;
  const { scope, machine } = r;
  if (!isStaffFor(scope, machine.customer_slug)) return json({ error: "not allowed" }, 403);
  if (!machine.backup_enabled) return json({ error: "this machine is not set up for backup" }, 409);
  let body: z.infer<typeof Body>;
  try { body = Body.parse(await readJson(req, 1_000)); } catch { return json({ error: "enter the new computer's name (letters, numbers and hyphens)" }, 400); }
  const id = await requestReplacement(machine.id, body.device, scope.username);
  if (!id) return json({ error: "there is already an open request for this computer" }, 409);
  await audit(scope, "replace.request", { customer: machine.customer_slug, machineId: machine.id, detail: { id, device: body.device } });
  return json({ id });
}
