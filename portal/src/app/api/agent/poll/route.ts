import { NextResponse } from "next/server";
import { z } from "zod";
import { q, q1 } from "@/lib/db";
import { authenticateAgent, readJson } from "@/lib/agentauth";

export const dynamic = "force-dynamic";

const epoch = z.number().int().min(0).max(4102444800);
const num = z.number().int().min(0).max(Number.MAX_SAFE_INTEGER);
const Body = z.object({
  agent_version: z.string().max(40).optional(),
  os: z.string().max(160).optional(),
  last_run: z.object({
    result: z.enum(["ok", "partial", "failed"]),
    run_epoch: epoch.optional(),
    success_epoch: epoch.optional(),
    duration_s: num.optional(),
    files_new: num.optional(),
    data_added: num.optional(),
    bytes_processed: num.optional(),
    snapshot_id: z.string().max(64).optional(),
    message: z.string().max(300).optional(),
  }).optional(),
  progress: z.object({
    percent_done: z.number().min(0).max(1).optional(),
    files_done: num.optional(),
    total_files: num.optional(),
    bytes_done: num.optional(),
    total_bytes: num.optional(),
  }).nullable().optional(),
}).strict();

// The agent's heartbeat: it reports its state, and is handed its backup policy and at most one job.
export async function POST(req: Request) {
  const agent = await authenticateAgent(req);
  if (!agent) return new NextResponse("unauthorized", { status: 401 });
  let body: z.infer<typeof Body>;
  try { body = Body.parse(await readJson(req, 16_384)); } catch { return new NextResponse("bad request", { status: 400 }); }

  await q("UPDATE machine SET last_seen = now(), agent_version = COALESCE($2, agent_version), os_desc = COALESCE($3, os_desc) WHERE id = $1",
    [agent.id, body.agent_version ?? null, body.os ?? null]);

  const r = body.last_run;
  if (r || body.progress !== undefined) {
    await q(
      `INSERT INTO backup_status(machine_id, result, last_run, last_success, duration_s, files_new, data_added, bytes_processed, snapshot_id, message, progress)
       VALUES ($1,$2, to_timestamp($3), to_timestamp($4), $5,$6,$7,$8,$9,$10,$11)
       ON CONFLICT (machine_id) DO UPDATE SET
         result = COALESCE($2, backup_status.result),
         last_run = COALESCE(to_timestamp($3), backup_status.last_run),
         last_success = COALESCE(to_timestamp($4), backup_status.last_success),
         duration_s = COALESCE($5, backup_status.duration_s), files_new = COALESCE($6, backup_status.files_new),
         data_added = COALESCE($7, backup_status.data_added), bytes_processed = COALESCE($8, backup_status.bytes_processed),
         snapshot_id = COALESCE($9, backup_status.snapshot_id), message = $10, progress = $11, updated_at = now()`,
      [agent.id, r?.result ?? null, r?.run_epoch ?? null, r?.success_epoch ?? null, r?.duration_s ?? null, r?.files_new ?? null,
       r?.data_added ?? null, r?.bytes_processed ?? null, r?.snapshot_id ?? null, r ? (r.message ?? null) : null,
       body.progress ? JSON.stringify(body.progress) : null]);
  }

  // Housekeeping for this machine's jobs.
  await q("UPDATE job SET status = 'expired', finished_at = now() WHERE machine_id = $1 AND status = 'queued' AND expires_at < now()", [agent.id]);
  await q("UPDATE job SET status = 'failed', error = 'the machine stopped responding', finished_at = now() WHERE machine_id = $1 AND status = 'running' AND updated_at < now() - interval '2 hours'", [agent.id]);

  const policy = await q1<{ include_paths: string[]; version: number }>("SELECT include_paths, version FROM policy WHERE machine_id = $1", [agent.id]);
  const schedule = await q1<{ days: number[]; at_time: string; version: number }>("SELECT days, at_time, version FROM schedule WHERE machine_id = $1", [agent.id]);
  const m = await q1<{ interactive: boolean }>("SELECT (interactive_until IS NOT NULL AND interactive_until > now()) AS interactive FROM machine WHERE id = $1", [agent.id]);

  // One job at a time: hand out the next only if none is running (long jobs run inside the agent's own poll).
  const job = await q1<{ id: string; type: string; params: unknown }>(
    `UPDATE job SET status = 'running', started_at = now(), updated_at = now()
      WHERE id = (SELECT id FROM job WHERE machine_id = $1 AND status = 'queued' AND expires_at > now()
                    AND NOT EXISTS (SELECT 1 FROM job r WHERE r.machine_id = $1 AND r.status = 'running' AND r.type <> 'backup_now')
                   ORDER BY requested_at LIMIT 1 FOR UPDATE SKIP LOCKED)
      RETURNING id, type, params`, [agent.id]);

  return NextResponse.json({
    interactive: !!m?.interactive,
    policy: policy ? { version: policy.version, include: policy.include_paths } : null,
    schedule: schedule ? { version: schedule.version, days: schedule.days, time: schedule.at_time } : null,
    job: job ?? null,
  });
}
