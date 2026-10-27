import { withMachine, json } from "@/lib/api";
import { ScheduleSchema } from "@/lib/jobs";
import { setSchedule } from "@/lib/data";
import { audit } from "@/lib/audit";
import { readJson } from "@/lib/agentauth";

export const dynamic = "force-dynamic";

// Choose when the backup runs. The agent picks it up at its next check-in and re-schedules its own task.
export async function PUT(req: Request, ctx: { params: Promise<{ id: string }> }) {
  const r = await withMachine(req, (await ctx.params).id, { write: true });
  if (r instanceof Response) return r;
  const { scope, machine } = r;
  if (!machine.backup_enabled) return json({ error: "this machine is not set up for backup" }, 409);
  let parsed;
  try { parsed = ScheduleSchema.parse(await readJson(req, 2_000)); } catch { return json({ error: "choose at least one day and a valid time" }, 400); }
  const days = [...new Set(parsed.days)].sort((a, b) => a - b);
  await setSchedule(machine.id, days, parsed.time, scope.username);
  await audit(scope, "schedule.set", { customer: machine.customer_slug, machineId: machine.id, detail: { days, time: parsed.time } });
  return json({ ok: true, days, time: parsed.time });
}
