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
  sched_days: number[] | null; sched_time: string | null;
};

const MACHINE_SELECT = `
  SELECT m.id, m.customer_slug, m.site_slug, m.name, m.display_name, m.backup_enabled, m.last_seen, m.os_desc, m.agent_version,
         c.name AS customer_name,
         b.result, b.last_run, b.last_success, b.files_new, b.data_added, b.bytes_processed, b.message, b.progress,
         (p.machine_id IS NOT NULL) AS has_policy, sc.days AS sched_days, sc.at_time AS sched_time
    FROM machine m
    JOIN customer c ON c.slug = m.customer_slug
    LEFT JOIN backup_status b ON b.machine_id = m.id
    LEFT JOIN policy p ON p.machine_id = m.id
    LEFT JOIN schedule sc ON sc.machine_id = m.id
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

export type ScheduleRow = { days: number[]; at_time: string; version: number; updated_by: string; updated_at: string };

export async function getSchedule(machineId: string) {
  return q1<ScheduleRow>("SELECT days, at_time, version, updated_by, updated_at FROM schedule WHERE machine_id = $1", [machineId]);
}

export async function setSchedule(machineId: string, days: number[], time: string, by: string) {
  await q(
    `INSERT INTO schedule(machine_id, days, at_time, updated_by) VALUES ($1,$2,$3,$4)
     ON CONFLICT (machine_id) DO UPDATE SET days = $2, at_time = $3, version = schedule.version + 1, updated_by = $4, updated_at = now()`,
    [machineId, JSON.stringify(days), time, by]);
}

// ---- catalog: what each backup contains, read from the portal's own database (filled by scripts/backup-catalog.sh) ----

export type CatalogSnapshot = { id: string; time: string; host: string; paths: string[] };
export type CatalogEntry = { name: string; path: string; type: "dir" | "file"; size: number };
export type CatalogHit = { snapshot: string; path: string; type: "dir" | "file"; size: number; mtime: string | null; taken_at: string };

export async function catalogSnapshots(machineId: string): Promise<CatalogSnapshot[]> {
  const rows = await q<{ snapshot_id: string; taken_at: string; paths: string[] }>(
    "SELECT snapshot_id, taken_at, paths FROM catalog_snapshot WHERE machine_id = $1 ORDER BY taken_at DESC LIMIT 200", [machineId]);
  return rows.map((r) => ({ id: r.snapshot_id, time: r.taken_at, host: "", paths: r.paths }));
}

const join = (parent: string, name: string) => (parent === "/" ? `/${name}` : `${parent}/${name}`);

/** The direct children of one folder as it was in one backup. "/" is the list of drives. */
export async function catalogLs(machineId: string, snapshot: string, path: string): Promise<{ entries: CatalogEntry[]; truncated: boolean }> {
  const parent = path.length > 1 ? path.replace(/\/+$/, "") : "/";
  const rows = await q<{ name: string; kind: string; size: string }>(
    `SELECT f.name, f.kind, f.size
       FROM catalog_file f
       JOIN catalog_snapshot s ON s.machine_id = f.machine_id AND s.snapshot_id = $2 AND s.seq = ANY(f.snaps)
      WHERE f.machine_id = $1 AND f.parent = $3
      ORDER BY (f.kind = 'd') DESC, lower(f.name) LIMIT 5001`, [machineId, snapshot, parent]);
  const truncated = rows.length > 5000;
  return { truncated, entries: rows.slice(0, 5000).map((r) => ({ name: r.name, path: join(parent, r.name), type: r.kind === "d" ? "dir" : "file", size: Number(r.size) })) };
}

/** A file-name search. Plain text matches anywhere in the name; * and ? work as wildcards. One hit per distinct version. */
export async function catalogSearch(machineId: string, pattern: string): Promise<{ hits: CatalogHit[]; truncated: boolean }> {
  const esc = pattern.replace(/[\\%_]/g, "\\$&");
  const like = /[*?]/.test(pattern) ? esc.replace(/\*/g, "%").replace(/\?/g, "_") : `%${esc}%`;
  const rows = await q<{ parent: string; name: string; kind: string; size: string; mtime: string; snapshot_id: string; taken_at: string }>(
    `SELECT f.parent, f.name, f.kind, f.size, f.mtime, s.snapshot_id, s.taken_at
       FROM catalog_file f
       CROSS JOIN LATERAL (SELECT s.snapshot_id, s.taken_at FROM catalog_snapshot s
                            WHERE s.machine_id = f.machine_id AND s.seq = ANY(f.snaps) ORDER BY s.taken_at DESC LIMIT 1) s
      WHERE f.machine_id = $1 AND f.name ILIKE $2
      ORDER BY lower(f.name), f.parent, f.mtime DESC LIMIT 501`, [machineId, like]);
  return {
    truncated: rows.length > 500,
    hits: rows.slice(0, 500).map((r) => ({
      snapshot: r.snapshot_id, path: join(r.parent, r.name), type: r.kind === "d" ? "dir" : "file", size: Number(r.size),
      mtime: r.kind === "d" ? null : r.mtime, taken_at: r.taken_at,
    })),
  };
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

export type ActivityRow = { at: string; actor: string; action: string; ip: string | null; computer: string | null; customer: string | null; detail: any };

// Routine reading (opening folders, listing backups) is audited but would drown the feed.
const QUIET_ACTIONS = ["catalog.browse", "job.ls_snapshot", "job.list_snapshots"];

/** The latest things people did, only for customers this person may see. Sign-ins carry no customer, so only administrators see them. */
export async function recentActivity(scope: Scope, limit = 15): Promise<ActivityRow[]> {
  return q<ActivityRow>(
    `SELECT a.at, a.actor, a.action, a.ip, a.detail, COALESCE(m.display_name, m.name) AS computer, c.name AS customer
       FROM audit a
       LEFT JOIN machine m ON m.id = a.machine_id
       LEFT JOIN customer c ON c.slug = a.customer_slug
      WHERE ($1::text[] IS NULL OR a.customer_slug = ANY($1)) AND a.action <> ALL($3::text[])
      ORDER BY a.at DESC LIMIT $2`, [visibleCustomers(scope), limit, QUIET_ACTIONS]);
}

export async function restoresLast30Days(scope: Scope): Promise<number> {
  const r = await q1<{ n: string }>(
    `SELECT count(*) AS n FROM audit WHERE action = 'job.restore' AND at > now() - interval '30 days' AND ($1::text[] IS NULL OR customer_slug = ANY($1))`,
    [visibleCustomers(scope)]);
  return Number(r?.n ?? 0);
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
