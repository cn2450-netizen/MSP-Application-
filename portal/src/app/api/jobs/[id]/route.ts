import { getScope } from "@/lib/session";
import { getJob } from "@/lib/data";
import { json } from "@/lib/api";

export const dynamic = "force-dynamic";

export async function GET(_req: Request, ctx: { params: Promise<{ id: string }> }) {
  const scope = await getScope();
  if (!scope) return json({ error: "not signed in" }, 401);
  const job = await getJob(scope, (await ctx.params).id);
  if (!job) return json({ error: "not found" }, 404);
  return json({ id: job.id, type: job.type, status: job.status, progress: job.progress, result: job.result, error: job.error });
}
