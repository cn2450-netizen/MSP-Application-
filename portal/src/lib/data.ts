import { q, q1 } from "./db";
import { visibleCustomers, canSee, type Scope } from "./authz";
import { JobSchemas, JobTtlMinutes, type JobType } from "./jobs";

// All reads go through here with a Scope, so a page cannot forget to filter by customer.

export type MachineRow = {
  id: string; customer_slug: string; site_slug: string; name: string; display_name: string | null;
  backup_enabled: boolean; last_seen: string | null; os_desc: string | null; agent_version: string | null;
  customer_name: string;
  result: string | null; last_run: string | null; last_success: string | null; files_new: string | null;
  data_added: string | null; bytes_processed: string | null; message: string | null; progress: any | null;
  has_policy: boolean;
};

const MACHINE_SELECT = `
  SELECT m.id, m.customer_slug, m.site_slug, m.name, m.display_name, m.backup_enabled, m.last_seen, m.os_desc, m.agent_version,
         c.name AS customer_name,
         b.result, b.last_run, b.last_success, b.files_new, b.data_added, b.bytes_processed, b.message, b.progress,
         (p.machine_id IS NOT NULL) AS has_policy
    FROM machine m
    JOIN customer c ON c.slug = m.customer_slug
    LEFT JOIN backup_status b ON b.machine_id = m.id
    LEFT JOIN policy p ON p.machine_id = m.id
   WHERE NOT m.retired AND ($1::text[] IS NULL OR m.customer_slug = ANY($1))`;

export function listMachines(scope: Scope): Promise<MachineRow[]> {
  return q<MachineRow>(`${MACHINE_SELECT} ORDER BY c.name, m.site_slug, m.name`, [visibleCustomers(scope)]);
}

export async function getMachine(scope: Scope, id: string): Promise<MachineRow | null> {
  if (!/^[0-9a-f-]{36}$/.test(id)) return null;
  return q1<MachineRow>(`${MACHINE_SELECT} AND m.id = $2`, [visibleCustomers(scope), id]);
}

export async function getPolicy(machineId: string) {
  return q1<{ include_paths: string[]; version: number; updated_by: string; updated_at: string }>(
    "SELECT include_paths, version, updated_by, updated_at FROM policy WHERE machine_id = $1", [machineId]);
}

export async function setPolicy(machineId: string, include: string[], by: string) {
  await q(
    `INSERT INTO policy(machine_id, include_paths, updated_by) VALUES ($1,$2,$3)
     ON CONFLICT (machine_id) DO UPDATE SET include_paths = $2, version = policy.version + 1, updated_by = $3, updated_at = now()`,
    [machineId, JSON.stringify(include), by]);
}

/** Validates the parameters, then queues the job. Throws if they are not valid for that job type. */
export async function createJob(machineId: string, type: JobType, params: unknown, requestedBy: string) {
  const clean = JobSchemas[type].parse(params);
  const row = await q1<{ id: string }>(
    `INSERT INTO job(machine_id, type, params, requested_by, expires_at)
     VALUES ($1,$2,$3,$4, now() + make_interval(mins => $5)) RETURNING id`,
    [machineId, type, JSON.stringify(clean), requestedBy, JobTtlMinutes[type]]);
  return row!.id;
}

export type JobRow = { id: string; machine_id: string; type: string; status: string; progress: any; result: any; error: string | null; requested_by: string };

/** A job, only if the person may see its machine. */
export async function getJob(scope: Scope, id: string): Promise<JobRow | null> {
  if (!/^[0-9a-f-]{36}$/.test(id)) return null;
  const j = await q1<JobRow & { customer_slug: string }>(
    `SELECT j.id, j.machine_id, j.type, j.status, j.progress, j.result, j.error, j.requested_by, m.customer_slug
       FROM job j JOIN machine m ON m.id = j.machine_id WHERE j.id = $1`, [id]);
  if (!j || !canSee(scope, j.customer_slug)) return null;
  return j;
}

export async function recentJobs(machineId: string, limit = 8) {
  return q<{ id: string; type: string; status: string; requested_by: string; requested_at: string; error: string | null }>(
    `SELECT id, type, status, requested_by, requested_at, error FROM job WHERE machine_id = $1 ORDER BY requested_at DESC LIMIT $2`,
    [machineId, limit]);
}

export async function markInteractive(machineId: string) {
  await q("UPDATE machine SET interactive_until = now() + interval '10 minutes' WHERE id = $1", [machineId]);
}

/** Healthy / attention / waiting, in the plain terms the pages use. */
export function health(m: Pick<MachineRow, "result" | "last_success" | "backup_enabled">): { key: "ok" | "warn" | "bad" | "none"; label: string } {
  if (!m.backup_enabled) return { key: "none", label: "Not backed up" };
  if (!m.last_success) return m.result === "failed" ? { key: "bad", label: "Backup failed" } : { key: "none", label: "No backup yet" };
  const hours = (Date.now() - new Date(m.last_success).getTime()) / 3600_000;
  if (hours > 54) return { key: "bad", label: "No recent backup" };
  if (m.result === "failed") return { key: "bad", label: "Last backup failed" };
  if (hours > 30 || m.result === "partial") return { key: "warn", label: "Needs a look" };
  return { key: "ok", label: "Protected" };
}
