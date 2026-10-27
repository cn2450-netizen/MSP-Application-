import { withMachine, json } from "@/lib/api";
import { catalogSnapshots, createJob, markInteractive } from "@/lib/data";
import { isStaffFor } from "@/lib/authz";
import { audit } from "@/lib/audit";

export const dynamic = "force-dynamic";

// After a computer has been replaced: put the newest backup's folders back where they were, on the new computer.
// Staff only. Existing files are never replaced (a new computer has none worth keeping).
export async function POST(req: Request, ctx: { params: Promise<{ id: string }> }) {
  const r = await withMachine(req, (await ctx.params).id, { write: true });
  if (r instanceof Response) return r;
  const { scope, machine } = r;
  if (!isStaffFor(scope, machine.customer_slug)) return json({ error: "not allowed" }, 403);
  if (!machine.backup_enabled) return json({ error: "this machine is not set up for backup" }, 409);

  const snap = (await catalogSnapshots(machine.id))[0];
  if (!snap) return json({ error: "there is no backup of this computer to restore yet" }, 409);
  // "D:\Users" -> "/D/Users"
  const items = snap.paths.map((p) => p.replace(/^([A-Za-z]):\\?/, "/$1/").replace(/\\/g, "/").replace(/(.)\/+$/, "$1")).slice(0, 50);
  if (items.length === 0) return json({ error: "the newest backup lists no folders" }, 409);

  let id: string;
  try { id = await createJob(machine.id, "restore", { snapshot: snap.id, items, target: "original", overwrite: "never" }, scope.username); }
  catch { return json({ error: "could not start the restore" }, 400); }
  await markInteractive(machine.id);
  await audit(scope, "job.restore", { customer: machine.customer_slug, machineId: machine.id, detail: { job: id, params: { snapshot: snap.id.slice(0, 8), items, target: "original" }, why: "restore after replacement" } });
  return json({ id, taken_at: snap.time, items });
}
