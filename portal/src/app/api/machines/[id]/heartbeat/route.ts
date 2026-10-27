import { withMachine, json } from "@/lib/api";
import { markInteractive } from "@/lib/data";

export const dynamic = "force-dynamic";

// A page that is waiting on the machine calls this so its agent switches to fast polling for a few minutes.
export async function POST(req: Request, ctx: { params: Promise<{ id: string }> }) {
  const r = await withMachine(req, (await ctx.params).id, { write: true });
  if (r instanceof Response) return r;
  await markInteractive(r.machine.id);
  return json({ ok: true });
}
