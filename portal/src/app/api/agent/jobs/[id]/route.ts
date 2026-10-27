import { NextResponse } from "next/server";
import { z } from "zod";
import { q1 } from "@/lib/db";
import { authenticateAgent, readJson } from "@/lib/agentauth";

export const dynamic = "force-dynamic";

const Body = z.object({
  status: z.enum(["running", "done", "failed"]),
  progress: z.record(z.string().max(40), z.union([z.number(), z.string().max(200)])).optional(),
  result: z.unknown().optional(),
  error: z.string().max(500).optional(),
}).strict();

// The agent reports progress or the final result of a job it was given. It can only touch its own machine's running jobs.
export async function POST(req: Request, ctx: { params: Promise<{ id: string }> }) {
  const { id } = await ctx.params;
  const agent = await authenticateAgent(req);
  if (!agent) return new NextResponse("unauthorized", { status: 401 });
  if (!/^[0-9a-f-]{36}$/.test(id)) return new NextResponse("bad request", { status: 400 });
  let body: z.infer<typeof Body>;
  try { body = Body.parse(await readJson(req, 3_000_000)); } catch { return new NextResponse("bad request", { status: 400 }); }

  const done = body.status !== "running";
  const row = await q1<{ id: string }>(
    `UPDATE job SET status = $3, progress = COALESCE($4, progress), result = COALESCE($5, result), error = $6,
                    updated_at = now(), finished_at = CASE WHEN $7 THEN now() ELSE finished_at END
      WHERE id = $1 AND machine_id = $2 AND status = 'running' RETURNING id`,
    [id, agent.id, body.status, body.progress ? JSON.stringify(body.progress) : null,
     body.result !== undefined ? JSON.stringify(body.result) : null, body.error ?? null, done]);
  if (!row) return new NextResponse("no such running job", { status: 404 });
  return NextResponse.json({ ok: true });
}
