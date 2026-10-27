import { withMachine, json } from "@/lib/api";
import { PolicySchema } from "@/lib/jobs";
import { setPolicy } from "@/lib/data";
import { audit } from "@/lib/audit";
import { readJson } from "@/lib/agentauth";

export const dynamic = "force-dynamic";

// Choose what is backed up. The agent picks the new list up at its next check-in and uses it from the next backup on.
export async function PUT(req: Request, ctx: { params: Promise<{ id: string }> }) {
  const r = await withMachine(req, (await ctx.params).id, { write: true });
  if (r instanceof Response) return r;
  const { scope, machine } = r;
  if (!machine.backup_enabled) return json({ error: "this machine is not set up for backup" }, 409);
  let parsed;
  try { parsed = PolicySchema.parse(await readJson(req, 100_000)); } catch { return json({ error: "choose at least one valid folder" }, 400); }
  const include = [...new Set(parsed.include)];
  await setPolicy(machine.id, include, scope.username);
  await audit(scope, "policy.set", { customer: machine.customer_slug, machineId: machine.id, detail: { include } });
  return json({ ok: true, include });
}
