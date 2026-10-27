import { z } from "zod";

// Everything a user can ask an agent to do is described here, and every parameter is validated BEFORE a job is
// created. The agent validates again before acting: it never trusts the network.

const noControl = (s: string) => !/[\u0000-\u001f]/.test(s);

/** A Windows path: "" (list the drives) or X:\folder\sub. No "..", no characters Windows forbids in names. */
export const winPath = z.string().max(400).refine(noControl).refine((p) => {
  if (p === "") return true;
  if (!/^[A-Za-z]:\\/.test(p)) return false;
  const parts = p.slice(3).split("\\").filter((x) => x !== "");
  return parts.every((x) => x !== ".." && x !== "." && !/[<>:"|?*]/.test(x));
}, "not a valid Windows path");

/** A path inside a snapshot: /C/Users/bob/Documents (drive letter first). */
export const snapPath = z.string().min(1).max(600).refine(noControl).refine(
  (p) => p.startsWith("/") && !p.split("/").some((x) => x === ".." || x === "."),
  "not a valid snapshot path",
);

export const snapshotId = z.string().regex(/^([0-9a-f]{8,64}|latest)$/);

export const JobSchemas = {
  list_dirs: z.object({ path: winPath }).strict(),
  backup_now: z.object({}).strict(),
  list_snapshots: z.object({}).strict(),
  ls_snapshot: z.object({ snapshot: snapshotId, path: snapPath }).strict(),
  find: z.object({
    pattern: z.string().min(1).max(100).refine(noControl).refine((s) => !s.startsWith("-")),
    snapshot: snapshotId.optional(),
  }).strict(),
  restore: z.object({
    snapshot: snapshotId,
    items: z.array(snapPath).min(1).max(50),
    drive: z.string().regex(/^[A-Z]$/).optional(),
  }).strict(),
} as const;

export type JobType = keyof typeof JobSchemas;

/** How long an unanswered request stays valid. Interactive screens give up quickly; restores may wait for a machine to come online. */
export const JobTtlMinutes: Record<JobType, number> = {
  list_dirs: 10, backup_now: 30, list_snapshots: 10, ls_snapshot: 10, find: 15, restore: 24 * 60,
};

/** The folders/files a person may choose to back up: drive-rooted folders, never "" (the drive list) and no wildcards. */
export const backupPath = winPath.refine((p) => p !== "" && !/[*]/.test(p), "choose a folder");
export const PolicySchema = z.object({ include: z.array(backupPath).min(1).max(200) }).strict();
