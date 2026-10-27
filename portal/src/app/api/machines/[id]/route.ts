import { withMachine, json } from "@/lib/api";
import { health } from "@/lib/data";

export const dynamic = "force-dynamic";

// Live status for the machine page (progress of a running backup, last result).
export async function GET(req: Request, ctx: { params: Promise<{ id: string }> }) {
  const r = await withMachine(req, (await ctx.params).id, { write: false });
  if (r instanceof Response) return r;
  const m = r.machine;
  return json({ health: health(m), result: m.result, last_run: m.last_run, last_success: m.last_success, progress: m.progress, message: m.message, last_seen: m.last_seen });
}
