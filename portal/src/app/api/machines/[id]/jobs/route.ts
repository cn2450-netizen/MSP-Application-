import { z } from "zod";
import { withMachine, json } from "@/lib/api";
import { JobSchemas, type JobType } from "@/lib/jobs";
import { createJob, markInteractive } from "@/lib/data";
import { isStaffFor } from "@/lib/authz";
import { audit } from "@/lib/audit";
import { readJson } from "@/lib/agentauth";

export const dynamic = "force-dynamic";

// Who may ask the machine's agent to do what. Customers manage their own machines; searching every snapshot is staff-only.
const STAFF_ONLY: JobType[] = ["find"];
// Listing live folders is not audited (folder names of the machine the person already sees); reading BACKUP contents is.
const AUDITED: JobType[] = ["backup_now", "ls_snapshot", "list_snapshots", "find", "restore"];

const Body = z.object({ type: z.enum(Object.keys(JobSchemas) as [JobType, ...JobType[]]), params: z.unknown() });

export async function POST(req: Request, ctx: { params: Promise<{ id: string }> }) {
  const r = await withMachine(req, (await ctx.params).id, { write: true });
  if (r instanceof Response) return r;
  const { scope, machine } = r;

  let body: z.infer<typeof Body>;
  try { body = Body.parse(await readJson(req, 20_000)); } catch { return json({ error: "bad request" }, 400); }
  if (STAFF_ONLY.includes(body.type) && !isStaffFor(scope, machine.customer_slug)) return json({ error: "not allowed" }, 403);
  if (!machine.backup_enabled) return json({ error: "this machine is not set up for backup" }, 409);
  // Putting files back where they came from can replace live data: staff only.
  const p = body.params as { target?: string } | null | undefined;
  if (body.type === "restore" && p?.target === "original" && !isStaffFor(scope, machine.customer_slug)) return json({ error: "not allowed" }, 403);

  let id: string;
  try { id = await createJob(machine.id, body.type, body.params ?? {}, scope.username); }
  catch { return json({ error: "invalid parameters" }, 400); }
  await markInteractive(machine.id);
  if (AUDITED.includes(body.type)) {
    await audit(scope, `job.${body.type}`, { customer: machine.customer_slug, machineId: machine.id, detail: { job: id, params: body.params } });
  }
  return json({ id });
}
