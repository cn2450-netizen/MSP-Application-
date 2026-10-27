import { withMachine, json } from "@/lib/api";
import { catalogLs, catalogSearch, catalogSnapshots } from "@/lib/data";
import { snapPath, snapshotId } from "@/lib/jobs";
import { isStaffFor } from "@/lib/authz";
import { audit } from "@/lib/audit";

export const dynamic = "force-dynamic";

// Reads the catalog (what each backup contains) from the portal's own database, so it answers at once without
// involving the computer. Same access rules as everything else: the machine must be one this person may see, and
// searching across every backup is staff-only. Reading backup contents is audited.
//   ?view=snapshots
//   ?view=ls&snapshot=<64 hex>&path=/D/Users
//   ?view=search&q=budget            (staff)
export async function GET(req: Request, ctx: { params: Promise<{ id: string }> }) {
  const r = await withMachine(req, (await ctx.params).id, { write: false });
  if (r instanceof Response) return r;
  const { scope, machine } = r;
  if (!machine.backup_enabled) return json({ error: "this machine is not set up for backup" }, 409);
  const u = new URL(req.url);
  const view = u.searchParams.get("view");
  const base = { customer: machine.customer_slug, machineId: machine.id };

  if (view === "snapshots") {
    return json({ snapshots: await catalogSnapshots(machine.id) });
  }
  if (view === "ls") {
    const snap = snapshotId.safeParse(u.searchParams.get("snapshot"));
    const path = snapPath.safeParse(u.searchParams.get("path") ?? "/");
    if (!snap.success || !path.success || snap.data === "latest" || snap.data.length !== 64) return json({ error: "bad request" }, 400);
    await audit(scope, "catalog.browse", { ...base, detail: { snapshot: snap.data.slice(0, 8), path: path.data } });
    return json(await catalogLs(machine.id, snap.data, path.data));
  }
  if (view === "search") {
    if (!isStaffFor(scope, machine.customer_slug)) return json({ error: "not allowed" }, 403);
    const q = (u.searchParams.get("q") ?? "").trim();
    if (q.length < 1 || q.length > 100 || /[\u0000-\u001f]/.test(q)) return json({ error: "bad request" }, 400);
    await audit(scope, "catalog.search", { ...base, detail: { pattern: q } });
    return json(await catalogSearch(machine.id, q));
  }
  return json({ error: "bad request" }, 400);
}
